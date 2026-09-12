import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal

// MARK: - Errors

public enum WalkVideoError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case frameNotFound(Int)
    case notPlanar
    case unsupportedPixelFormat(OSType)
    case noMetalDevice
    case pixelBufferAllocationFailed
    case writerRejectedSettings(String)
    case nonMonotonicTimestamp(sourceFrame: Int)
    /// The control that defect #721 did not have. A writer that reports success
    /// and produces a short file must fail here, not later and quietly.
    case shortOutput(appended: Int, decodable: Int, url: URL)

    public var description: String {
        switch self {
        case .noVideoTrack(let u):        return "no video track in \(u.lastPathComponent)"
        case .frameNotFound(let i):       return "frame \(i) could not be decoded"
        case .notPlanar:                  return "pixel buffer is not planar; the Y plane cannot be read directly"
        case .unsupportedPixelFormat(let f): return "unsupported pixel format \(fourCC(f))"
        case .noMetalDevice:              return "no Metal device"
        case .pixelBufferAllocationFailed: return "CVPixelBufferCreate failed"
        case .writerRejectedSettings(let s): return "AVAssetWriter refused the output settings: \(s)"
        case .nonMonotonicTimestamp(let f): return "retimed output timestamp did not increase at source frame \(f)"
        case .shortOutput(let a, let d, let u):
            return "SHORT OUTPUT: appended \(a) frames, \(d) are decodable in \(u.lastPathComponent) — \(a - d) lost with no error from the writer"
        }
    }
}

public func fourCC(_ c: FourCharCode) -> String {
    String(bytes: [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff),
                   UInt8((c >> 8) & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? "????"
}

// MARK: - What the file says about itself

public struct VideoInfo: Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    /// The track's own `minFrameDuration`, kept as a rational. Never collapse it
    /// to a Double before arithmetic: 1001/60000 is not 1/59.94 and the rounding
    /// shows up as an off-by-one frame index halfway through a long clip.
    public let frameDuration: CMTime
    public let nominalFrameRate: Double
    public let duration: CMTime
    /// Frames implied by duration / frameDuration. Reported as an ESTIMATE
    /// because it is arithmetic on the container's timing, not a decode count.
    /// `FrameScanner` reports the decoded count, which is the measured one.
    public let estimatedFrameCount: Int
    public let codec: String
    public let bitDepth: Int?
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let estimatedDataRateMbps: Double

    public var megapixels: Double { Double(width * height) / 1e6 }
    public var fps: Double { 1.0 / CMTimeGetSeconds(frameDuration) }
    public var seconds: Double { CMTimeGetSeconds(duration) }

    /// True only if the container claims BT.2020 primaries AND the HLG transfer
    /// function. Note what this does NOT prove: #495 measured that a request for
    /// an 8-bit buffer still delivers every HLG/BT.2020 attachment, so colour
    /// tags survive when the bits do not. Bit depth is proved by reading the Y
    /// plane, never by checking a tag.
    public var isHLGBT2020: Bool {
        colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
            && transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }
}

// MARK: - A frame, and the reason it is shaped this way

/// One decoded frame.
///
/// It carries a `CVReadOnlyPixelBuffer` rather than a `CVPixelBuffer` because
/// `CVPixelBuffer` is not `Sendable` and `CVReadOnlyPixelBuffer` is. That makes
/// `Frame` a value you can hand across isolation domains; the pixels are reached
/// through `withPixelBuffer`, which is synchronous by design.
///
/// MEASURED consequence, and it constrains every caller: `withPixelBuffer`
/// returns its result as `sending`, so a `CVPixelBuffer`, `CIImage` or `CGImage`
/// CANNOT be returned out of it. Compute inside the closure and return values,
/// or call `detachedCopy()` to get a buffer you own. Anything else is a compile
/// error — the good kind.
public struct Frame: Sendable {
    public let index: Int
    public let pts: CMTime
    public let buffer: CVReadOnlyPixelBuffer

    public var time: Double { CMTimeGetSeconds(pts) }

    public init(index: Int, pts: CMTime, buffer: CVReadOnlyPixelBuffer) {
        self.index = index; self.pts = pts; self.buffer = buffer
    }

    public func withPixelBuffer<R>(_ body: (CVPixelBuffer) throws -> sending R) rethrows -> sending R {
        try buffer.withUnsafeBuffer(body)
    }

    public struct Shape: Sendable {
        public let width: Int, height: Int, pixelFormat: OSType, planes: Int
        public var pixelFormatName: String { fourCC(pixelFormat) }
    }

    public var shape: Shape {
        withPixelBuffer { pb in
            Shape(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                  pixelFormat: CVPixelBufferGetPixelFormatType(pb),
                  planes: CVPixelBufferGetPlaneCount(pb))
        }
    }

    /// A buffer this caller owns, outliving the reader that produced it.
    ///
    /// The destination is allocated OUTSIDE `withPixelBuffer` and only written
    /// to inside it, because a `CVPixelBuffer` cannot leave that closure's
    /// `sending` result. Needed for Vision (whose modern async API takes a
    /// `CVPixelBuffer`) and for the app's thumbnails.
    public func detachedCopy() -> CVPixelBuffer? {
        let s = shape
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, s.width, s.height, s.pixelFormat,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                  &out) == kCVReturnSuccess, let dst = out else { return nil }
        withPixelBuffer { src in
            CVPixelBufferLockBaseAddress(src, .readOnly)
            CVPixelBufferLockBaseAddress(dst, [])
            let planes = max(CVPixelBufferGetPlaneCount(src), 1)
            for p in 0..<planes {
                guard let sb = CVPixelBufferGetBaseAddressOfPlane(src, p),
                      let db = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { continue }
                let sr = CVPixelBufferGetBytesPerRowOfPlane(src, p)
                let dr = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
                let h = CVPixelBufferGetHeightOfPlane(src, p)
                for y in 0..<h { memcpy(db.advanced(by: y * dr), sb.advanced(by: y * sr), min(sr, dr)) }
            }
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVBufferPropagateAttachments(src, dst)
        }
        return dst
    }

    /// Direct 10-bit Y-plane statistics, in CODE VALUES.
    ///
    /// This is the measurement that agrees with `ffmpeg signalstats` to three
    /// decimals on 33 of 33 frames (decision #495) and it is the known-answer
    /// path: frame 2347 of clip 0012 is 439.098 against a 414.176 neighbour.
    ///
    /// UNDOCUMENTED LAYOUT, measured, and Apple's page is wrong about it:
    /// `420YpCbCr10BiPlanarVideoRange` stores its 10 bits LEFT-ALIGNED in a
    /// UInt16, so the code value is `word >> 6`. The documented [64,940] range
    /// describes code values, not the words in memory.
    public func yPlaneStats(stride step: Int = 1) throws -> YPlaneStats {
        try withPixelBuffer { pb in
            guard CVPixelBufferIsPlanar(pb) else { throw WalkVideoError.notPlanar }
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                      || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else {
                throw WalkVideoError.unsupportedPixelFormat(fmt)
            }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0)
            let h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            var sum = 0.0, n = 0, lo = Int.max, hi = Int.min
            var allWordsMultipleOf64 = tenBit
            let s = max(1, step)
            if tenBit {
                for y in stride(from: 0, to: h, by: s) {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    var x = 0
                    while x < w {
                        let word = Int(row[x])
                        if word & 0x3F != 0 { allWordsMultipleOf64 = false }
                        let v = word >> 6
                        sum += Double(v); n += 1
                        if v < lo { lo = v }; if v > hi { hi = v }
                        x += s
                    }
                }
            } else {
                for y in stride(from: 0, to: h, by: s) {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    var x = 0
                    while x < w {
                        let v = Int(row[x]); sum += Double(v); n += 1
                        if v < lo { lo = v }; if v > hi { hi = v }
                        x += s
                    }
                }
            }
            guard n > 0 else { throw WalkVideoError.notPlanar }
            return YPlaneStats(mean: sum / Double(n), min: lo, max: hi,
                               samples: n, bits: tenBit ? 10 : 8,
                               allWordsMultipleOf64: allWordsMultipleOf64)
        }
    }

    /// Colour attachments as the decoder actually delivered them.
    public func colorAttachments() -> [String: String] {
        withPixelBuffer { pb in
            var out = [String: String]()
            for k in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                      kCVImageBufferYCbCrMatrixKey] {
                if let v = CVBufferCopyAttachment(pb, k, nil) {
                    out[k as String] = String(describing: v)
                }
            }
            if let cs = CVBufferCopyAttachment(pb, kCVImageBufferCGColorSpaceKey, nil) {
                let space = unsafeDowncast(cs, to: CGColorSpace.self)
                out["CGColorSpace"] = (space.name as String?) ?? "<unnamed>"
            }
            return out
        }
    }
}

public struct YPlaneStats: Sendable {
    public let mean: Double
    public let min: Int
    public let max: Int
    public let samples: Int
    public let bits: Int
    /// True when every 16-bit word is a multiple of 64 — the signature of the
    /// left-aligned 10-bit layout, and therefore proof the bits survived. Colour
    /// tags do not prove this; #495 measured them surviving an 8-bit buffer.
    public let allWordsMultipleOf64: Bool
    /// Peak headroom is the real reason to pin 10-bit. #495: at 8 bits the
    /// brightest strike frame clips at Ymax 255; at 10 bits it is 1017 of 1023.
    public var isClipped: Bool { max >= (bits == 10 ? 1023 : 255) }
}

// MARK: - VideoReader

/// Opens an asset, reports what it is, and hands out frames.
///
/// Uses the macOS 26 replacement reader API throughout — `outputProvider(for:)`,
/// `start()`, `Provider.next()`. Nothing here is deprecated; see Package.swift
/// for why the platform floor moved to make that possible.
public final class VideoReader {

    public static let tenBitVideoRange = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// The working colour space, PINNED, and this is load-bearing.
    ///
    /// MEASURED, decision #495: the default `CIContext` working space is
    /// `ExtendedLinearSRGB`, not BT.2020. On the same lightning frame the event
    /// reads +36.03% in pinned linear BT.2020, +36.34% in the default linear
    /// sRGB, and +8.54% in an sRGB working space with RGBA8 — the detector is
    /// 4.2x more sensitive in linear light. A context left at its default
    /// silently throws away most of the signal.
    public static var workingColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    }

    /// The pinned working space's name as a plain String, for reports.
    public static var workingColorSpaceName: String {
        guard let n = workingColorSpace.name else { return "<unnamed>" }
        return n as String
    }

    public let url: URL
    public let info: VideoInfo
    let asset: AVURLAsset
    let track: AVAssetTrack

    public init(url: URL) async throws {
        self.url = url
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw WalkVideoError.noVideoTrack(url)
        }
        self.track = track

        let duration = try await asset.load(.duration)
        let frameDuration = try await track.load(.minFrameDuration)
        let nominal = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.estimatedDataRate)
        let formats = try await track.load(.formatDescriptions)

        var codec = "????", bits: Int? = nil
        var primaries: String? = nil, transfer: String? = nil, matrix: String? = nil
        if let fd = formats.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            bits = (ext["BitsPerComponent"] as? NSNumber)?.intValue
            primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String
            transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String
            matrix = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
        }
        let fdSec = CMTimeGetSeconds(frameDuration)
        self.info = VideoInfo(
            url: url, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            frameDuration: frameDuration, nominalFrameRate: Double(nominal), duration: duration,
            estimatedFrameCount: fdSec > 0 ? Int((CMTimeGetSeconds(duration) / fdSec).rounded()) : 0,
            codec: codec, bitDepth: bits, colorPrimaries: primaries,
            transferFunction: transfer, yCbCrMatrix: matrix,
            estimatedDataRateMbps: Double(rate) / 1e6)
    }

    /// A `CIContext` with the working space pinned. Always build one through
    /// here; see `workingColorSpace`.
    public static func makeContext() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw WalkVideoError.noMetalDevice }
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .highQualityDownsample: false,
        ])
    }

    // MARK: Addressing

    public func time(ofFrame index: Int) -> CMTime {
        CMTimeMultiply(info.frameDuration, multiplier: Int32(clamping: index))
    }

    public func frameIndex(of pts: CMTime) -> Int {
        let fd = CMTimeGetSeconds(info.frameDuration)
        guard fd > 0 else { return 0 }
        return Int((CMTimeGetSeconds(pts) / fd).rounded())
    }

    /// `HH:MM:SS:FF` at the clip's own rate.
    public func timecode(ofFrame index: Int) -> String {
        let fps = Swift.max(1, Int(info.fps.rounded()))
        let total = Swift.max(0, index)
        let f = total % fps, s = (total / fps) % 60, m = (total / (fps * 60)) % 60, h = total / (fps * 3600)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    // MARK: One pass over the file

    /// A single forward pass. One `Pass` owns one `AVAssetReader`; make a new one
    /// for each traversal rather than trying to rewind.
    public final class Pass {
        private let reader: AVAssetReader
        private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        private let frameDurationSeconds: Double
        private var started = false
        public private(set) var delivered = 0

        init(reader: AVAssetReader,
             provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
             frameDurationSeconds: Double) {
            self.reader = reader
            self.provider = provider
            self.frameDurationSeconds = frameDurationSeconds
        }

        public func next() async throws -> Frame? {
            if !started { try reader.start(); started = true }
            while let ready = try await provider.next() {
                // A pass with nil outputSettings can deliver marker-only samples;
                // a decoded pass should not, but the cast is the honest filter.
                guard let pixels = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(ready) else { continue }
                delivered += 1
                let pts = pixels.presentationTimeStamp
                let index = frameDurationSeconds > 0
                    ? Int((CMTimeGetSeconds(pts) / frameDurationSeconds).rounded()) : delivered - 1
                return Frame(index: index, pts: pts, buffer: pixels.content)
            }
            return nil
        }

        public func cancel() { reader.cancelReading() }
        public var status: AVAssetReader.Status { reader.status }
        public var error: Error? { reader.error }
    }

    /// Open a pass. `frames == nil` reads the whole file.
    ///
    /// NOTE on trimming: a DECODED pass (non-nil outputSettings, which is what
    /// this always uses) honours the requested start frame. A passthrough pass
    /// does not — it snaps back to the preceding sync sample, which is cause (3)
    /// of open defect task #721. `VideoWriter` re-encodes for that reason.
    public func pass(frames: Range<Int>? = nil,
                     pixelFormat: OSType = VideoReader.tenBitVideoRange) throws -> Pass {
        let reader = try AVAssetReader(asset: asset)
        if let frames, !frames.isEmpty {
            reader.timeRange = CMTimeRange(
                start: time(ofFrame: frames.lowerBound),
                duration: CMTimeMultiply(info.frameDuration, multiplier: Int32(clamping: frames.count)))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ])
        // NEW API: outputProvider(for:) both attaches the output and returns the
        // provider. `reader.add(_:)` and `alwaysCopiesSampleData` are deprecated
        // on macOS 27 and are not used anywhere in WalkKit.
        let provider = reader.outputProvider(for: output)
        return Pass(reader: reader, provider: provider,
                    frameDurationSeconds: CMTimeGetSeconds(info.frameDuration))
    }

    // MARK: Single frames

    /// One frame by index, with an owned buffer so it survives the reader.
    ///
    /// Frame-exact addressing is MEASURED (#495): requesting PTS 2349347/60000
    /// for frame 2347 returns exactly that PTS. Cold seek 39 s into a 4K60 clip
    /// cost 0.125 s, warm 0.039–0.058 s.
    public func frame(at index: Int,
                      pixelFormat: OSType = VideoReader.tenBitVideoRange) async throws -> Frame {
        // Two frames of slack: the range must contain the target even when the
        // container's timing rounds the start down.
        let p = try pass(frames: index..<(index + 2), pixelFormat: pixelFormat)
        defer { p.cancel() }
        guard let f = try await p.next() else { throw WalkVideoError.frameNotFound(index) }
        guard let owned = f.detachedCopy() else { throw WalkVideoError.pixelBufferAllocationFailed }
        return Frame(index: f.index, pts: f.pts, buffer: CVReadOnlyPixelBuffer(unsafeBuffer: owned))
    }

    public func frame(atPTS pts: CMTime) async throws -> Frame {
        try await frame(at: frameIndex(of: pts))
    }
}
