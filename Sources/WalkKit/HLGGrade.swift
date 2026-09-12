import Foundation
import CoreImage

/// HLG (ITU-R BT.2100) → SDR Rec.709 conversion, plus a filmic grade.
///
/// Written because the shipped ffmpeg on this machine has no `zscale`, so no
/// correct transfer-function conversion existed. HLG is a CAPTURE format: it is
/// deliberately flat so the grade is a later decision. Viewing it untransformed
/// is not "flat footage", it is an unapplied transform.
public enum HLGGrade {

    /// Per-pixel: inverse HLG OETF → OOTF → BT.2020→709 primaries → filmic
    /// tone map. Emits LINEAR Rec.709 so CoreImage owns the final sRGB encode.
    ///
    /// Every constant below is from the standard, not tuned by eye:
    ///   a, b, c          BT.2100 Table 5 HLG inverse OETF
    ///   0.2627/0.6780/0.0593   BT.2020 luma coefficients
    ///   system gamma 1.2 is the BT.2100 nominal for a 1000 cd/m² reference display
    private static let kernelSource = """
    kernel vec4 hlgToLinear709(__sample s, float exposure, float systemGamma) {
        const float a = 0.17883277;
        const float b = 0.28466892;
        const float c = 0.55991073;

        vec3 e = clamp(s.rgb, 0.0, 1.0);

        // Inverse HLG OETF — piecewise, selected per component without branching.
        vec3 lo = (e * e) / 3.0;
        vec3 hi = (exp((e - vec3(c)) / a) + vec3(b)) / 12.0;
        vec3 lin = mix(hi, lo, step(e, vec3(0.5)));

        // OOTF: scene light -> display light. Y is BT.2020 luma.
        float Y = dot(lin, vec3(0.2627, 0.6780, 0.0593));
        lin = lin * pow(max(Y, 1e-6), systemGamma - 1.0);

        // BT.2020 -> Rec.709 primaries, linear light.
        vec3 r709 = vec3(
            dot(lin, vec3( 1.6605, -0.5876, -0.0728)),
            dot(lin, vec3(-0.1246,  1.1329, -0.0083)),
            dot(lin, vec3(-0.0182, -0.1006,  1.1187))
        );
        r709 = max(r709, vec3(0.0));
        r709 = r709 * exposure;

        // Hable filmic curve — holds highlight detail instead of clipping it,
        // which is the whole point on a frame containing a lightning strike.
        const float A = 0.15, B = 0.50, C2 = 0.10, D = 0.20, E2 = 0.02, F = 0.30;
        const float W = 11.2;
        vec3 x = r709;
        vec3 curved = ((x * (A * x + C2 * B) + D * E2) / (x * (A * x + B) + D * F)) - E2 / F;
        float wn = ((W * (A * W + C2 * B) + D * E2) / (W * (A * W + B) + D * F)) - E2 / F;
        vec3 outc = clamp(curved / wn, 0.0, 1.0);

        return vec4(outc, s.a);
    }
    """

    private static let kernel: CIColorKernel = {
        guard let k = CIColorKernel(source: kernelSource) else {
            fatalError("HLG kernel failed to compile")
        }
        return k
    }()

    /// HLG OOTF system gamma, derived from the TARGET display luminance.
    ///
    /// ITU-R BT.2390: `γ = 1.2 + 0.42 · log10(Lw / 1000)`
    ///
    /// This is the single most important number in the transform and the easiest
    /// to get wrong, because 1.2 is quoted everywhere as "the" HLG system gamma.
    /// 1.2 is the value for a 1000 cd/m² reference HDR display. For a 100 cd/m²
    /// SDR display it is 0.78. Gamma above 1 DARKENS shadows; below 1 LIFTS them.
    ///
    /// Measured consequence, 2026-09-12, first run of this engine: hardcoding 1.2
    /// while rendering to SDR crushed the entire foreground of a storm frame to
    /// pure black — the treeline and houses that gave the lightning strike its
    /// scale were gone. The picture looked like an aggressive grade. It was a
    /// units error.
    public static func systemGamma(targetNits: Double) -> Float {
        Float(1.2 + 0.42 * log10(max(targetNits, 1.0) / 1000.0))
    }

    public struct Look: Sendable {
        public var exposure: Float
        public var targetNits: Double
        public var contrast: Float
        public var saturation: Float
        public var vibrance: Float
        public var shadowLift: Float
        public var highlightPull: Float

        public var systemGamma: Float { HLGGrade.systemGamma(targetNits: targetNits) }

        /// The transform only, no interpretation. This is what "correct" looks
        /// like; every other look is a deliberate departure from it.
        public static let neutral = Look(
            exposure: 1.0, targetNits: 100, contrast: 1.0,
            saturation: 1.0, vibrance: 0.0, shadowLift: 0.0, highlightPull: 0.0
        )

        /// Broadcast-weather look. Restrained on purpose: the drama in a storm
        /// frame is the subject, and a grade that manufactures more of it reads
        /// as a filter. Saturation stays near unity because pushing it on a
        /// near-neutral storm sky is what produced the magenta cast on the first
        /// run of this engine — the same defect class as the 2026-09-10
        /// overcorrection that Pixel §9.8 exists to prevent.
        public static let dramatic = Look(
            exposure: 1.05, targetNits: 100, contrast: 1.12,
            saturation: 1.02, vibrance: 0.12, shadowLift: 0.15, highlightPull: -0.10
        )

        public init(exposure: Float, targetNits: Double, contrast: Float,
                    saturation: Float, vibrance: Float,
                    shadowLift: Float, highlightPull: Float) {
            self.exposure = exposure; self.targetNits = targetNits
            self.contrast = contrast; self.saturation = saturation
            self.vibrance = vibrance; self.shadowLift = shadowLift
            self.highlightPull = highlightPull
        }
    }

    /// Apply the transform and the look. Input must be RAW HLG values with
    /// colour management disabled on load, or the numbers are already wrong
    /// before this function sees them.
    public static func apply(to input: CIImage, look: Look) -> CIImage {
        var img = kernel.apply(
            extent: input.extent,
            arguments: [input, look.exposure, look.systemGamma]
        ) ?? input

        if look.shadowLift != 0 || look.highlightPull != 0 {
            let f = CIFilter(name: "CIHighlightShadowAdjust")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(1.0 + look.shadowLift, forKey: "inputShadowAmount")
            f.setValue(1.0 + look.highlightPull, forKey: "inputHighlightAmount")
            img = f.outputImage ?? img
        }

        if look.contrast != 1.0 || look.saturation != 1.0 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(look.contrast, forKey: kCIInputContrastKey)
            f.setValue(look.saturation, forKey: kCIInputSaturationKey)
            img = f.outputImage ?? img
        }

        if look.vibrance != 0 {
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(look.vibrance, forKey: "inputAmount")
            img = f.outputImage ?? img
        }

        return img.cropped(to: input.extent)
    }

    public struct Reading: Sendable {
        public let r, g, b, luma: Double
        /// Max channel minus min channel. On a near-neutral subject this is the
        /// cast: it should not GROW across a grade.
        public var spread: Double { max(r, max(g, b)) - min(r, min(g, b)) }
        public var valid: Bool { r.isFinite && g.isFinite && b.isFinite }
    }

    /// Mean channel values over the whole image — the measurement half of the loop.
    /// CIAreaAverage was measured at 8.0 ms for 24 MP in decision #490.
    ///
    /// `colorSpace` MUST match how the image is encoded. Passing a managed space
    /// for an unmanaged (raw) image returns NaN, silently — measured 2026-09-12,
    /// and it produced a graded result reported with no valid baseline, which is
    /// the one thing the method forbids. `valid` exists so a caller cannot miss it.
    public static func mean(_ image: CIImage,
                            context: CIContext,
                            colorSpace: CGColorSpace?) -> Reading {
        let f = CIFilter(name: "CIAreaAverage")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
        guard let out = f.outputImage else { return Reading(r: .nan, g: .nan, b: .nan, luma: .nan) }
        var px = [Float](repeating: 0, count: 4)
        context.render(out,
                       toBitmap: &px,
                       rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: colorSpace)
        let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
        return Reading(r: r, g: g, b: b, luma: 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }

    /// Measure an UNMANAGED image — raw file values, colour management disabled.
    ///
    /// Does NOT use CIAreaAverage. Measured 2026-09-12: CIAreaAverage returns NaN
    /// on an unmanaged image, with no error and no warning, because the reduction
    /// has no working colour space to reduce in. It renders the full buffer and
    /// averages on the CPU instead — slower, and correct, which is the right
    /// trade for a baseline taken once per grade.
    ///
    /// This is the same silent-failure class as Pixel §9.1: an API that returns a
    /// plausible-shaped result containing nothing.
    public static func meanRaw(_ image: CIImage) -> Reading {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0 else { return Reading(r: .nan, g: .nan, b: .nan, luma: .nan) }

        let count = w * h
        var buf = [Float](repeating: 0, count: count * 4)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(image,
                       toBitmap: raw.baseAddress!,
                       rowBytes: w * 16,
                       bounds: image.extent,
                       format: .RGBAf,
                       colorSpace: nil)
        }

        var sr = 0.0, sg = 0.0, sb = 0.0
        for i in stride(from: 0, to: count * 4, by: 4) {
            sr += Double(buf[i]); sg += Double(buf[i + 1]); sb += Double(buf[i + 2])
        }
        let n = Double(count)
        let r = sr / n, g = sg / n, b = sb / n
        return Reading(r: r, g: g, b: b, luma: 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
}
