import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Writes a frame range to a new file. RE-ENCODE ONLY.
///
/// WHY PASSTHROUGH IS NOT HERE, and it is not an omission.
///
/// Open defect task #721, measured 2026-09-12 and recorded in decision #495:
/// writing a trimmed range through `AVAssetWriter` passthrough appended 122
/// samples, EVERY `append()` returned true, `writer.status` was `.completed`,
/// `writer.error` was nil — and the file held 100 decodable frames. 22 frames
/// gone, with no error surfaced anywhere in the API. Surviving frames were
/// bit-exact, so spot-checking any one of them passes while a fifth of the
/// footage is missing. Three causes were found, two fixed, and the third —
/// passthrough trim cannot start mid-GOP, so a request for frame 2300 snaps back
/// to 2280 — was NOT root-caused.
///
/// Passthrough is 15,479 fps against 86.6 for re-encode, a 180x difference, so
/// it is worth fixing and task #721 is open against it. It is not worth shipping
/// until a trimmed passthrough range produces a file whose decodable frame count
/// equals the requested count on at least two clips, AND a deliberately induced
/// failure surfaces as an error rather than as a short file.
///
/// MEASURED cost of the honest path: the re-encode round trip moved frame 2347's
/// Y mean from 439.098 to 439.079 — a delta of 0.019 code values, 0.0044%,
/// through a full HEVC Main10 encode and decode.
public struct VideoWriter: Sendable {

    public struct Options: Sendable {
        /// Output frame rate. Every source frame becomes one output frame, so a
        /// 60 fps source conformed to 30 plays at half speed and keeps every
        /// frame — which is the point when the event is one frame long.
        public var targetFrameRate: Int32
        public var averageBitRate: Int
        public var fileType: AVFileType
        /// Re-read the finished file and count its decodable frames. Leave this
        /// on. It is the control defect #721 did not have.
        public var verifyByReadback: Bool

        public init(targetFrameRate: Int32 = 30,
                    averageBitRate: Int = 130_000_000,
                    fileType: AVFileType = .mov,
                    verifyByReadback: Bool = true) {
            self.targetFrameRate = targetFrameRate
            self.averageBitRate = averageBitRate
            self.fileType = fileType
            self.verifyByReadback = verifyByReadback
        }
    }

    public struct Report: Sendable {
        public let url: URL
        public let sourceFrames: Range<Int>
        public let framesRequested: Int
        public let framesPulled: Int
        public let framesAppended: Int
        /// Decoded back out of the finished file. `nil` only if verification was
        /// switched off, and then the report says so rather than implying success.
        public let framesDecodable: Int?
        public let outputSeconds: Double
        public let outputFrameRate: Double
        public let encodeSeconds: Double
        public let bytes: Int
        public let retimeRatio: (numerator: Int32, denominator: Int32)
        public let codec: String
        public let colorPrimaries: String?
        public let transferFunction: String?
        public let yCbCrMatrix: String?
        public let bitDepth: Int?

        public var framesPerSecondEncoded: Double {
            encodeSeconds > 0 ? Double(framesAppended) / encodeSeconds : 0
        }
        public var verified: Bool { framesDecodable == framesAppended }
        public var verificationNote: String {
            guard let d = framesDecodable else {
                return "NOT VERIFIED — readback was disabled, so a short file would not have been noticed"
            }
            return d == framesAppended
                ? "verified — \(d) decodable frames equals \(framesAppended) appended"
                : "SHORT — \(framesAppended) appended, \(d) decodable, \(framesAppended - d) lost silently"
        }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    public func write(_ reader: VideoReader, frames: Range<Int>, to url: URL) async throws -> Report {
        try? FileManager.default.removeItem(at: url)

        let info = reader.info
        let writer = try AVAssetWriter(url: url, fileType: options.fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            // HLG and BT.2020 are carried through explicitly. Readback confirms
            // hvc1 / 10 bit / ITU_R_2020 / ITU_R_2100_HLG.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.averageBitRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
        ]
        // canApply is an INSTANCE method. #495 recorded Apple's documentation
        // describing it as a type method, which does not compile.
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw WalkVideoError.writerRejectedSettings("HEVC Main10 + HLG at \(info.width)x\(info.height)")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // NEW API: inputPixelBufferReceiver attaches the input AND returns the
        // receiver. AVAssetWriterInputPixelBufferAdaptor, writer.add(_:),
        // startWriting() and requestMediaDataWhenReady are all deprecated on
        // macOS 27 and none of them appear in WalkKit.
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)

        // EXACT INTEGER RATIO, and it has to be exact.
        //
        // outputFrameDuration / sourceFrameDuration
        //   = (1/targetFPS) / (fd.value/fd.timescale)
        //   = fd.timescale / (targetFPS * fd.value)
        // For 1001/60000 at 30 fps that is 60000/30030 = 2000/1001.
        //
        // MEASURED 2026-09-12: computing this through a Double truncated
        // 2000/1001 to 1999/1001. Every frame still landed, the file still
        // verified, and the output came back 3.3317 s at 31.58 fps instead of
        // 3.3333 s at 30.00 — a wrong answer that passes every check except
        // reading the duration.
        var num = Int32(info.frameDuration.timescale)
        var den = options.targetFrameRate * Int32(info.frameDuration.value)
        let g = Self.gcd(num, den)
        if g > 0 { num /= g; den /= g }

        let pass = try reader.pass(frames: frames)
        defer { pass.cancel() }
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        var pulled = 0, appended = 0
        var firstPTS: CMTime? = nil
        var lastOut = CMTime.negativeInfinity
        let t0 = DispatchTime.now().uptimeNanoseconds

        while let frame = try await pass.next() {
            pulled += 1
            if firstPTS == nil { firstPTS = frame.pts }
            let outPTS = CMTimeMultiplyByRatio(CMTimeSubtract(frame.pts, firstPTS!),
                                               multiplier: num, divisor: den)
            // Strictly increasing or stop. A repeated or backwards timestamp is
            // how frames disappear into a writer that reports success.
            guard CMTimeCompare(outPTS, lastOut) > 0 else {
                input.markAsFinished()
                await writer.finishWriting()
                throw WalkVideoError.nonMonotonicTimestamp(sourceFrame: frame.index)
            }
            lastOut = outPTS
            try await receiver.append(frame.buffer, with: outPTS)
            appended += 1
        }
        let encodeSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        input.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw writer.error ?? WalkVideoError.writerRejectedSettings("writer status \(writer.status.rawValue)")
        }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0

        // ---- READBACK ----
        var decodable: Int? = nil
        var outSeconds = 0.0, outFPS = 0.0
        var codec = "????", primaries: String? = nil, transfer: String? = nil
        var matrix: String? = nil, bits: Int? = nil
        if options.verifyByReadback {
            let back = try await VideoReader(url: url)
            outSeconds = back.info.seconds
            outFPS = back.info.fps
            codec = back.info.codec
            primaries = back.info.colorPrimaries
            transfer = back.info.transferFunction
            matrix = back.info.yCbCrMatrix
            bits = back.info.bitDepth
            let verify = try back.pass()
            defer { verify.cancel() }
            var count = 0
            while let _ = try await verify.next() { count += 1 }
            decodable = count
        }

        let report = Report(
            url: url, sourceFrames: frames, framesRequested: frames.count,
            framesPulled: pulled, framesAppended: appended, framesDecodable: decodable,
            outputSeconds: outSeconds, outputFrameRate: outFPS,
            encodeSeconds: encodeSeconds, bytes: bytes,
            retimeRatio: (num, den), codec: codec, colorPrimaries: primaries,
            transferFunction: transfer, yCbCrMatrix: matrix, bitDepth: bits)

        if let decodable, decodable != appended {
            throw WalkVideoError.shortOutput(appended: appended, decodable: decodable, url: url)
        }
        return report
    }

    static func gcd(_ a: Int32, _ b: Int32) -> Int32 { b == 0 ? a : gcd(b, a % b) }
}
