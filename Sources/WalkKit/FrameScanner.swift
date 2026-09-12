import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

/// One frame's measurement.
public struct LumaSample: Sendable {
    public let index: Int
    public let time: Double
    /// BT.2020 luma of the frame's mean colour, computed in PINNED linear
    /// BT.2020 light. The detector runs on this.
    public let ciLuma: Double
    public let r: Double, g: Double, b: Double
    /// 10-bit Y-plane code mean — the known-answer measurement, and the one that
    /// agrees with `ffmpeg signalstats`. `nil` unless `Options.computeYPlane`.
    public let yMean: Double?
    public let yMax: Int?
    public let yClipped: Bool?

    public var valid: Bool { ciLuma.isFinite && r.isFinite && g.isFinite && b.isFinite }
}

public struct LumaSeries: Sendable {
    public let url: URL
    public let samples: [LumaSample]
    public let frameDuration: CMTime
    /// DECODED frame count. This is measured, unlike `VideoInfo.estimatedFrameCount`.
    public var decodedFrames: Int { samples.count }
    public let wallSeconds: Double
    public let ciMillisecondsPerFrame: Double
    public var framesPerSecond: Double { wallSeconds > 0 ? Double(samples.count) / wallSeconds : 0 }
    /// Frame indices the decoder never delivered inside the scanned span. Empty
    /// is the expected answer; a non-empty list is a reportable fact, not a
    /// rounding curiosity.
    public let missingIndices: [Int]

    public func sample(at index: Int) -> LumaSample? { samples.first { $0.index == index } }
    public var values: [Double] { samples.map(\.ciLuma) }
    public var indices: [Int] { samples.map(\.index) }
}

/// Per-frame whole-image luminance across a whole clip.
public struct FrameScanner {

    public struct Options: Sendable {
        /// `nil` scans the whole file.
        public var frames: Range<Int>?
        /// Read the 10-bit Y plane as well as the Core Image mean. Adds a full
        /// CPU pass over the Y plane per frame, so it is off by default and on
        /// for the known-answer path.
        public var computeYPlane: Bool
        /// Sub-sampling step for the Y pass. MUST be 1 for the known answer;
        /// `stride > 1` changes the mean and the reference numbers no longer apply.
        public var yPlaneStride: Int
        public var pixelFormat: OSType

        public init(frames: Range<Int>? = nil, computeYPlane: Bool = false,
                    yPlaneStride: Int = 1, pixelFormat: OSType = VideoReader.tenBitVideoRange) {
            self.frames = frames; self.computeYPlane = computeYPlane
            self.yPlaneStride = yPlaneStride; self.pixelFormat = pixelFormat
        }
    }

    public static func scan(_ reader: VideoReader,
                            options: Options = Options(),
                            progress: (@Sendable (Int) -> Void)? = nil) async throws -> LumaSeries {
        let context = try VideoReader.makeContext()
        let pass = try reader.pass(frames: options.frames, pixelFormat: options.pixelFormat)
        defer { pass.cancel() }

        var samples = [LumaSample]()
        samples.reserveCapacity(options.frames?.count ?? reader.info.estimatedFrameCount)
        var ciSeconds = 0.0
        let t0 = DispatchTime.now().uptimeNanoseconds

        while let frame = try await pass.next() {
            // CANCELLATION IS CHECKED PER FRAME, AND IT WAS NOT BEFORE.
            //
            // MEASURED 2026-09-12: a `notifications/cancelled` for a scan of a
            // 15,367-frame clip was received and registered, the task's flag was
            // set, and the decoder kept going — because the only
            // checkCancellation in the path sat in ClipScan's candidate loop,
            // which runs AFTER the whole scan. Cancellation was acknowledged and
            // nothing stopped, which is the defect class this library is about:
            // a success signal with nothing behind it.
            //
            // One flag read per frame against ~2.6 ms of decode and Core Image
            // work is not measurable.
            try Task.checkCancellation()
            // AUTORELEASEPOOL IS NOT HOUSEKEEPING, IT IS 6x.
            //
            // MEASURED 2026-09-12 on clip 0012, 2771 frames of 4K60, identical
            // code either side of this line:
            //   without autoreleasepool   38.724 s wall, 71.6 fps, CI 2.686 ms/frame
            //   with autoreleasepool       6.454 s wall, 429.4 fps, CI 1.893 ms/frame
            // The unaccounted time — neither decode nor Core Image — fell from
            // 31.3 s to 1.2 s. The Core Image temporaries pile up, the decoder's
            // buffer pool starves, and the loop spends its life waiting.
            //
            // The reason this comment exists: the numbers are IDENTICAL either
            // way. Without the pool you get the right answer, six times slower,
            // with no error and nothing to blame but the new async reader API,
            // which is innocent. Decode alone measures 628.4 fps on the new
            // path against 277.5 fps on the deprecated one.
            //
            // It wraps only the synchronous work. `pass.next()` is `await` and
            // cannot be inside an autoreleasepool.
            let sample: LumaSample? = autoreleasepool {
                let c0 = DispatchTime.now().uptimeNanoseconds
                let mean = frame.withPixelBuffer { pb -> (Double, Double, Double) in
                    let image = CIImage(cvPixelBuffer: pb)
                    // A FRESH filter per frame, measured faster than a shared one
                    // (429.4 fps vs 387.0 fps) — the shared instance keeps the
                    // previous frame's image alive.
                    let filter = CIFilter(name: "CIAreaAverage")!
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
                    guard let out = filter.outputImage else { return (.nan, .nan, .nan) }
                    var px = [Float](repeating: 0, count: 4)
                    px.withUnsafeMutableBytes { raw in
                        context.render(out, toBitmap: raw.baseAddress!, rowBytes: 16,
                                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                       format: .RGBAf, colorSpace: nil)
                    }
                    return (Double(px[0]), Double(px[1]), Double(px[2]))
                }
                ciSeconds += Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e9

                var yMean: Double? = nil, yMax: Int? = nil, yClipped: Bool? = nil
                if options.computeYPlane, let y = try? frame.yPlaneStats(stride: options.yPlaneStride) {
                    yMean = y.mean; yMax = y.max; yClipped = y.isClipped
                }
                // BT.2020 luma coefficients, ITU-R BT.2100 Table 4.
                let luma = 0.2627 * mean.0 + 0.6780 * mean.1 + 0.0593 * mean.2
                return LumaSample(index: frame.index, time: frame.time, ciLuma: luma,
                                  r: mean.0, g: mean.1, b: mean.2,
                                  yMean: yMean, yMax: yMax, yClipped: yClipped)
            }
            if let sample { samples.append(sample); progress?(sample.index) }
        }

        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        samples.sort { $0.index < $1.index }

        var missing = [Int]()
        if let first = samples.first?.index, let last = samples.last?.index, !samples.isEmpty {
            let present = Set(samples.map(\.index))
            for i in first...last where !present.contains(i) { missing.append(i) }
        }

        return LumaSeries(url: reader.url, samples: samples,
                          frameDuration: reader.info.frameDuration,
                          wallSeconds: wall,
                          ciMillisecondsPerFrame: samples.isEmpty ? 0 : ciSeconds / Double(samples.count) * 1000,
                          missingIndices: missing)
    }
}
