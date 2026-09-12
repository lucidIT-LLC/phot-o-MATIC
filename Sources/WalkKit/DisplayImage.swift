import Foundation
import CoreImage
import CoreGraphics
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers

extension HLGGrade {
    /// Tone map only — no inverse OETF, no OOTF.
    ///
    /// WHY THIS IS A SEPARATE KERNEL AND NOT `HLGGrade.apply`. `apply` takes
    /// RAW HLG code values off a file loaded with colour management DISABLED and
    /// runs the whole chain. A `CIImage(cvPixelBuffer:)` built from a decoded
    /// video frame is already colour-managed: AVFoundation's HLG attachment is
    /// honoured and Core Image hands over LINEAR LIGHT in the pinned working
    /// space. Running the inverse OETF on linear light would be a second
    /// decode of something already decoded — the same class of units error as
    /// the system-gamma-1.2 defect that crushed a storm foreground to black.
    ///
    /// So this applies only the part that is still owed: the Hable filmic curve,
    /// which holds a lightning highlight instead of clipping it. The BT.2020 to
    /// sRGB primary conversion is left to the context's output colour space.
    private static let displaySource = """
    kernel vec4 hableOnly(__sample s, float exposure) {
        const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
        const float W = 11.2;
        vec3 x = max(s.rgb, vec3(0.0)) * exposure;
        vec3 curved = ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
        float wn = ((W * (A * W + C * B) + D * E) / (W * (A * W + B) + D * F)) - E / F;
        return vec4(clamp(curved / wn, 0.0, 1.0), s.a);
    }
    """

    nonisolated(unsafe) private static let displayKernel: CIColorKernel = {
        guard let k = CIColorKernel(source: displaySource) else {
            fatalError("display tone-map kernel failed to compile")
        }
        return k
    }()

    /// Map a linear-light image to display range with the filmic curve.
    public static func tonemapForDisplay(_ image: CIImage, exposure: Float = 1.0) -> CIImage {
        (displayKernel.apply(extent: image.extent, arguments: [image, exposure]) ?? image)
            .cropped(to: image.extent)
    }
}

extension Frame {
    /// A viewable sRGB image of this frame.
    ///
    /// The pipeline, stated because every stage changes the numbers:
    ///   decoded 10-bit HLG BT.2020  ->  Core Image honours the attachment and
    ///   works in pinned linear BT.2020  ->  Hable filmic curve  ->  sRGB on
    ///   output.
    ///
    /// This is a PICTURE FOR LOOKING AT. It is not the measurement, and no number
    /// in Walk is derived from it. The measurements come from the Y plane and
    /// from CIAreaAverage in linear light, before any of this.
    public func makeDisplayImage(maxWidth: CGFloat = 480, exposure: Float = 1.0) -> CGImage? {
        // detachedCopy first: a CVPixelBuffer cannot leave withPixelBuffer's
        // `sending` result, and neither can a CIImage or a CGImage.
        guard let owned = detachedCopy() else { return nil }
        let source = CIImage(cvPixelBuffer: owned)
        let scale = maxWidth > 0 ? min(1.0, maxWidth / source.extent.width) : 1.0
        var image = HLGGrade.tonemapForDisplay(source, exposure: exposure)
        if scale < 1.0 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: VideoReader.workingColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
        return context.createCGImage(image, from: image.extent,
                                     format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

extension Frame {
    /// Write this frame as a tone-mapped sRGB PNG and return where it landed.
    ///
    /// WHY A FILE AND NOT BYTES, decided deliberately in 0.4.0 rather than
    /// defaulted into. The MCP front door hands its results to a language model,
    /// and a model's context is the scarcest thing in the system. MEASURED on
    /// this material: a 560-pixel-wide display PNG off a 4K frame is on the
    /// order of 300 KB, which is ~400 KB once base64-encoded, and #507 records
    /// one GoPro clip producing 38 candidates. Returning every candidate inline
    /// would be roughly 15 MB of images for one clip — the conversation would
    /// die before the operator saw anything.
    ///
    /// So candidates come back as PATHS, always, and the host reads the two or
    /// three worth looking at. `walk_scan` can also inline a small, capped
    /// number on request, which is the case where a picture is the answer.
    ///
    /// This is a PICTURE FOR LOOKING AT. No number in Walk is derived from it.
    public func writeDisplayPNG(to url: URL, maxWidth: CGFloat = 640,
                                exposure: Float = 1.0) throws -> URL {
        guard let cg = makeDisplayImage(maxWidth: maxWidth, exposure: exposure) else {
            throw WalkVideoError.pixelBufferAllocationFailed
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WalkVideoError.thumbnailWriteFailed(url)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WalkVideoError.thumbnailWriteFailed(url)
        }
        return url
    }
}
