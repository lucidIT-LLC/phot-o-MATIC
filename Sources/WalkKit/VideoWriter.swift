import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Writes a frame range to a new file. Two paths, and each proves its own count.
///
/// `write(_:frames:to:)` RE-ENCODES: HEVC Main10 + HLG, retimed by an exact
/// integer ratio, verified by reading the finished file back. MEASURED cost of
/// that path: the round trip moved frame 2347's Y mean from 439.098 to 439.079 —
/// a delta of 0.019 code values, 0.0044%, through a full HEVC encode and decode.
///
/// `passthrough(_:frames:to:)` COPIES THE STORED BITSTREAM, no decode and no
/// encode. It was open defect task #721 from 2026-09-12 to 2026-09-25, and the
/// history is kept here because the defect was in the instrument, not the file:
///
/// The 2026-09-12 spike (decision #495) appended 122 samples, every append
/// returned true, `writer.status` was `.completed`, `writer.error` was nil, and
/// "the file held 100 decodable frames" — reported as 22 frames lost. MEASURED
/// 2026-09-25 with the same request (clip 0012, frames 2300..<2400): the reader
/// delivers 120 media samples plus 4 zero-sample marker buffers. 2300 is twenty
/// frames into a 30-frame GOP, and compressed video decodes only from a sync
/// sample, so the reader starts at 2280 — twenty frames of LEAD-IN that must be
/// stored for the requested frames to decode at all. The file held exactly the
/// 100 frames that were asked for. Nothing was lost; the count of samples
/// appended was compared to a count of frames presented, and they are not the
/// same quantity. "Cannot start mid-GOP" was cause (3) and it is not a defect:
/// it is what a GOP is.
///
/// So the passthrough path does what Apple's own documentation describes and
/// nothing cleverer:
///   * samples go to the writer in DECODE order as delivered — append(_:) says
///     "order and append them according to their decode timestamp";
///   * `startSession(atSourceTime:)` is the REQUESTED start — "samples with
///     timestamps earlier than startTime will still be added to the output file
///     but will be edited out (i.e. not presented during playback)";
///   * `endSession(atSourceTime:)` is the REQUESTED end — the same sentence for
///     samples later than the end time;
///   * `SampleBufferReceiver.append(_:)` "suspends until the input is ready for
///     more media data", which is the documented replacement for the
///     `readyForMoreMediaData` loop and the reason the tight-loop
///     NSInternalInconsistencyException of 2026-09-12 cannot recur;
///   * every append has returned before `finishWriting()` — "to guarantee that
///     all sample buffers are successfully written, ensure all calls to
///     append have returned before invoking this method".
///
/// AND THE CONTROL: readback is not optional on this path. Frames requested and
/// frames decodable out of the finished file are compared, and a difference is
/// `WalkVideoError.frameCountMismatch` — an error, never a warning. A test
/// induces a loss and asserts it surfaces that way.
///
/// Sources, read 2026-09-25: AVAssetWriterInput.h (readyForMoreMediaData,
/// appendSampleBuffer:, markAsFinished), AVAssetWriter.h
/// (startSessionAtSourceTime:, endSessionAtSourceTime:,
/// finishWritingWithCompletionHandler:), AVAssetReader.h (timeRange), the
/// macOS 27.0 SDK, and developer.apple.com/documentation/avfoundation for
/// AVAssetWriterInput.SampleBufferReceiver.append(_:), appendImmediately(_:),
/// finish(), AVAssetWriter.inputReceiver(for:), and AVAssetReaderOutput.Provider.
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

        /// TEST HOOK, internal on purpose. When set, the passthrough path
        /// silently drops the media sample at this index before appending it.
        /// It exists so a test can prove the frame-count control CAN FAIL —
        /// the discipline every gate in this repository follows (`--selftest`).
        /// Nothing outside the test target can set it.
        var inducedLossForTesting: Int? = nil

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

    // MARK: - Passthrough

    public struct PassthroughReport: Sendable {
        public let url: URL
        public let sourceFrames: Range<Int>
        public let framesRequested: Int
        /// Media samples handed to the writer. INCLUDES the lead-in: the samples
        /// from the sync sample at or before the requested start, which the file
        /// must carry for the requested frames to decode. Not a frame count of
        /// the output, and never compared to one — that comparison was #721.
        public let samplesAppended: Int
        /// Samples before the requested start (GOP lead-in, stored, edited out).
        public let leadInSamples: Int
        /// Samples at or after the requested end (stored, edited out).
        public let pastEndSamples: Int
        /// Zero-sample marker buffers the reader delivered and the pass skipped.
        public let markersSkipped: Int
        /// Decoded back out of the finished file. Never nil: readback is not
        /// optional on this path.
        public let framesDecodable: Int
        public let outputSeconds: Double
        public let outputFrameRate: Double
        public let copySeconds: Double
        public let bytes: Int
        public let codec: String
        public let colorPrimaries: String?
        public let transferFunction: String?
        public let yCbCrMatrix: String?
        public let bitDepth: Int?

        public var framesPerSecondCopied: Double {
            copySeconds > 0 ? Double(samplesAppended) / copySeconds : 0
        }
        public var verified: Bool { framesDecodable == framesRequested }
        public var verificationNote: String {
            verified
                ? "verified — \(framesDecodable) decodable frames equals \(framesRequested) requested (\(samplesAppended) samples stored, \(leadInSamples) of them GOP lead-in edited out)"
                : "MISMATCH — \(framesRequested) requested, \(framesDecodable) decodable, \(framesRequested - framesDecodable) missing"
        }
    }

    /// Copy `frames` out of `reader` into a new file with NO decode and NO
    /// encode, and prove the count. See the type comment for what this closes.
    ///
    /// The output presents exactly `frames` — the GOP lead-in the container has
    /// to carry is stored and edited out by the session start time. Timestamps
    /// are the source's own; there is no retime on this path, because a retime
    /// of a compressed stream would change what the samples mean.
    public func passthrough(_ reader: VideoReader, frames: Range<Int>, to url: URL) async throws -> PassthroughReport {
        guard !frames.isEmpty else { throw WalkVideoError.emptyFrameRange }
        guard let hint = reader.formatDescription else {
            throw WalkVideoError.writerRejectedSettings("passthrough: the source track has no format description")
        }
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(url: url, fileType: options.fileType)
        // nil outputSettings IS the passthrough contract (AVAssetWriterInput.h:
        // "A value of nil indicates that the receiver will pass through appended
        // samples, doing no processing before they are written to the output").
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        // THE TIMESCALE IS THE SOURCE'S, NOT QUICKTIME'S DEFAULT OF 600.
        // MEASURED 2026-09-25 without these two lines: the output track came
        // back with time_base 1/600, every 1001/60000 s frame quantized to 10
        // ticks with a periodic 11 to catch up, avg_frame_rate 72000/1201, and
        // AVFoundation reading the file's frame rate as 59.88 against 59.94. The
        // frames were all there and the count verified — the timing had been
        // rewritten. A copy that keeps the bits and moves the clock is not a copy.
        input.mediaTimeScale = reader.info.frameDuration.timescale
        writer.movieTimeScale = reader.info.frameDuration.timescale
        let receiver = writer.inputReceiver(for: input)

        let start = reader.time(ofFrame: frames.lowerBound)
        let end = reader.time(ofFrame: frames.upperBound)

        let pass = try reader.passthroughPass(frames: frames)
        defer { pass.cancel() }
        try writer.start()
        writer.startSession(atSourceTime: start)

        var appended = 0, leadIn = 0, pastEnd = 0, seen = 0
        var lastDTS = CMTime.negativeInfinity
        let t0 = DispatchTime.now().uptimeNanoseconds

        while let sample = try await pass.next() {
            defer { seen += 1 }
            if let drop = options.inducedLossForTesting, drop == seen { continue }
            // Decode order is the storage requirement. A sample whose decode
            // timestamp does not advance is appended out of order, and the
            // writer will not tell you.
            let dts = sample.decodeTimeStamp.isValid ? sample.decodeTimeStamp : sample.presentationTimeStamp
            guard CMTimeCompare(dts, lastDTS) > 0 else {
                receiver.finish()
                await writer.finishWriting()
                throw WalkVideoError.nonMonotonicTimestamp(sourceFrame: reader.frameIndex(of: sample.presentationTimeStamp))
            }
            lastDTS = dts
            let pts = sample.presentationTimeStamp
            if CMTimeCompare(pts, start) < 0 { leadIn += 1 }
            if CMTimeCompare(pts, end) >= 0 { pastEnd += 1 }
            // Suspends until the input is ready. Throws if the writer failed.
            try await receiver.append(sample)
            appended += 1
        }
        let copySeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        writer.endSession(atSourceTime: end)
        receiver.finish()
        await writer.finishWriting()

        if writer.status != .completed {
            throw writer.error ?? WalkVideoError.writerRejectedSettings("writer status \(writer.status.rawValue)")
        }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0

        // ---- READBACK, NOT OPTIONAL ----
        let back = try await VideoReader(url: url)
        let verify = try back.pass()
        defer { verify.cancel() }
        var decodable = 0
        do {
            while let _ = try await verify.next() { decodable += 1 }
        } catch {
            // A decoder that refuses the file is the same verdict as a short
            // count, and it must not escape as a bare AVFoundation error that a
            // caller could mistake for a transient read problem.
            throw WalkVideoError.readbackFailed(requested: frames.count, decodedBeforeFailure: decodable,
                                                url: url, underlying: "\(error)")
        }

        let report = PassthroughReport(
            url: url, sourceFrames: frames, framesRequested: frames.count,
            samplesAppended: appended, leadInSamples: leadIn, pastEndSamples: pastEnd,
            markersSkipped: pass.markersSkipped, framesDecodable: decodable,
            outputSeconds: back.info.seconds, outputFrameRate: back.info.fps,
            copySeconds: copySeconds, bytes: bytes, codec: back.info.codec,
            colorPrimaries: back.info.colorPrimaries, transferFunction: back.info.transferFunction,
            yCbCrMatrix: back.info.yCbCrMatrix, bitDepth: back.info.bitDepth)

        guard report.verified else {
            throw WalkVideoError.frameCountMismatch(requested: frames.count, decodable: decodable, url: url)
        }
        return report
    }

    static func gcd(_ a: Int32, _ b: Int32) -> Int32 { b == 0 ? a : gcd(b, a % b) }
}
