import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import WalkKit

// TASK #721 — the passthrough write path, and the control it did not have.
//
// The 2026-09-12 measurement: 122 samples appended, every success signal true,
// "100 decodable frames", reported as 22 frames lost. Re-measured 2026-09-25
// (see VideoWriter's type comment): the file held exactly the 100 frames asked
// for, and the 22 were GOP lead-in plus marker buffers — samples that are not
// output frames, compared against a count of output frames. These tests pin the
// count that matters (requested == decodable), on two clips, at a mid-GOP start,
// and they prove the control can fail by inducing a loss and requiring an error.
//
// The material is the operator's archive on an external volume, so the fixture
// tests are conditional, exactly as KnownAnswerTests are. The report-shape tests
// below them run everywhere.

enum SecondClip {
    static let clipPath =
        "/Volumes/NVMeExt1/Content/Photography/Digital Negatives/storm/DJI_20260912051528_0011_D.MP4"
    static var url: URL { URL(fileURLWithPath: clipPath) }
    static var available: Bool { FileManager.default.fileExists(atPath: clipPath) }
}

private func scratchURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-passthrough-\(UUID().uuidString).mov")
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
func aPassthroughTrimHoldsExactlyTheFramesAskedFor() async throws {
    // THE #721 REQUEST, VERBATIM: clip 0012, frames 2300..<2400. 2300 is twenty
    // frames into a 30-frame GOP (key frames at 2280 and 2310, measured with
    // ffprobe -skip_frame nokey), so this is the mid-GOP start that was cause (3).
    let reader = try await VideoReader(url: KnownAnswer.url)
    let out = scratchURL()
    defer { try? FileManager.default.removeItem(at: out) }

    let r = try await VideoWriter().passthrough(reader, frames: 2300..<2400, to: out)
    #expect(r.framesRequested == 100)
    #expect(r.framesDecodable == 100, "frames in must equal frames out; got \(r.verificationNote)")
    #expect(r.verified)
    // What the 2026-09-12 spike miscounted, now named on the report.
    #expect(r.leadInSamples == 20, "decode starts at sync sample 2280; got \(r.leadInSamples) lead-in samples")
    #expect(r.samplesAppended == 120, "100 requested + 20 lead-in; got \(r.samplesAppended)")
    #expect(r.markersSkipped == 4, "the reader's zero-sample marker buffers; got \(r.markersSkipped)")
    // The file's own timeline is the requested range and nothing more.
    #expect(abs(r.outputSeconds - 100.0 * 1001.0 / 60000.0) < 0.001,
            "output must present 100 frames at 59.94; got \(r.outputSeconds) s")
    #expect(abs(r.outputFrameRate - 60000.0 / 1001.0) < 0.01, "no retime on this path")
    #expect(r.codec == "hvc1")
    #expect(r.bitDepth == 10)
    #expect(r.transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
    #expect(r.colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))

    // BIT-EXACT, not "within the re-encode delta". Source frame 2347 is output
    // frame 47 and its 10-bit Y mean is the known answer to three decimals.
    let back = try await VideoReader(url: out)
    let series = try await FrameScanner.scan(back, options: .init(frames: 45..<50, computeYPlane: true))
    let landed = try #require(series.sample(at: 47)?.yMean, "source frame 2347 must land at output frame 47")
    #expect(abs(landed - 439.098) < 0.0005, "a stored-bitstream copy must measure exactly; got \(landed)")
}

@Test(.enabled(if: SecondClip.available), .timeLimit(.minutes(5)))
func aPassthroughTrimIsExactOnASecondClipWithBothEndsMidGOP() async throws {
    // #721's acceptance asks for two of the six storm clips. Clip 0011,
    // 1234..<1361: the start is four frames past sync sample 1230 and the end is
    // eleven frames past sync sample 1350, so both edits are inside a GOP.
    let reader = try await VideoReader(url: SecondClip.url)
    let out = scratchURL()
    defer { try? FileManager.default.removeItem(at: out) }

    let r = try await VideoWriter().passthrough(reader, frames: 1234..<1361, to: out)
    #expect(r.framesRequested == 127)
    #expect(r.framesDecodable == 127, r.verificationNote == "" ? "" : "\(r.verificationNote)")
    #expect(r.verified)
    #expect(r.leadInSamples == 4, "decode starts at sync sample 1230; got \(r.leadInSamples)")
    #expect(r.samplesAppended == 127 + r.leadInSamples + r.pastEndSamples)
    #expect(abs(r.outputSeconds - 127.0 * 1001.0 / 60000.0) < 0.001)
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
func aKeyFrameAlignedRequestHasNoLeadIn() async throws {
    // The other edge: start ON a sync sample and there is nothing to edit out.
    let reader = try await VideoReader(url: KnownAnswer.url)
    let out = scratchURL()
    defer { try? FileManager.default.removeItem(at: out) }
    let r = try await VideoWriter().passthrough(reader, frames: 2280..<2400, to: out)
    #expect(r.framesDecodable == 120)
    #expect(r.leadInSamples == 0)
    #expect(r.samplesAppended == 120)
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
func anInducedLossSurfacesAsAnErrorNotAShortFile() async throws {
    // THE PROOF THE CONTROL CAN FAIL. #721's acceptance in terms: "a deliberate
    // induced failure is shown to surface as an error rather than a short
    // file." One media sample inside the requested range is dropped before it
    // reaches the writer; the writer will still report success (it did on
    // 2026-09-12 with far more missing). The readback must not.
    let reader = try await VideoReader(url: KnownAnswer.url)
    let out = scratchURL()
    defer { try? FileManager.default.removeItem(at: out) }
    var options = VideoWriter.Options()
    options.inducedLossForTesting = 50   // sample 50 of the pass = frame 2330, inside 2300..<2400
    let writer = VideoWriter(options: options)

    let thrown = await #expect(throws: WalkVideoError.self) {
        try await writer.passthrough(reader, frames: 2300..<2400, to: out)
    }
    // MEASURED 2026-09-25: the decoder refuses the damaged file at the missing
    // sample (AVFoundation -11821 "Cannot Decode") rather than returning fewer
    // frames, so the loss surfaces as `readbackFailed`. Had it decoded fewer, it
    // would surface as `frameCountMismatch`. Both are errors; neither is a file
    // that reports success. Anything else fails this test.
    switch try #require(thrown) {
    case .frameCountMismatch(let requested, let decodable, _):
        #expect(requested == 100)
        #expect(decodable < 100, "the induced loss must show up as fewer decodable frames; got \(decodable)")
    case .readbackFailed(let requested, let decoded, _, let why):
        #expect(requested == 100)
        #expect(decoded < 100, "the decoder must have stopped short; it decoded \(decoded)")
        #expect(why.contains("Cannot Decode") || why.contains("-11821"), "unexpected decoder reason: \(why)")
    default:
        Issue.record("expected frameCountMismatch or readbackFailed, got \(String(describing: thrown))")
    }
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(1)))
func anEmptyRangeIsRefusedNotWrittenEmpty() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)
    let out = scratchURL()
    defer { try? FileManager.default.removeItem(at: out) }
    await #expect(throws: WalkVideoError.self) {
        try await VideoWriter().passthrough(reader, frames: 10..<10, to: out)
    }
    #expect(!FileManager.default.fileExists(atPath: out.path))
}

// MARK: - Runs everywhere

@Test func thePassthroughReportCannotCallAMismatchVerified() {
    let url = URL(fileURLWithPath: "/x.mov")
    let short = VideoWriter.PassthroughReport(
        url: url, sourceFrames: 0..<100, framesRequested: 100,
        samplesAppended: 120, leadInSamples: 20, pastEndSamples: 0, markersSkipped: 4,
        framesDecodable: 99, outputSeconds: 1.65, outputFrameRate: 59.94, copySeconds: 0.1,
        bytes: 1, codec: "hvc1", colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil, bitDepth: 10)
    #expect(!short.verified)
    #expect(short.verificationNote.hasPrefix("MISMATCH"))
    #expect(short.verificationNote.contains("1 missing"))

    // And the comparison is requested-vs-decodable, NEVER appended-vs-decodable:
    // 120 appended against 100 decodable is the #721 miscount, and it is correct.
    let exact = VideoWriter.PassthroughReport(
        url: url, sourceFrames: 0..<100, framesRequested: 100,
        samplesAppended: 120, leadInSamples: 20, pastEndSamples: 0, markersSkipped: 4,
        framesDecodable: 100, outputSeconds: 1.668, outputFrameRate: 59.94, copySeconds: 0.1,
        bytes: 1, codec: "hvc1", colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil, bitDepth: 10)
    #expect(exact.verified)
    #expect(exact.verificationNote.hasPrefix("verified"))
    #expect(exact.verificationNote.contains("20 of them GOP lead-in"))
}

@Test func passthroughIsAContractedCapabilityAndNoLongerAbsent() {
    #expect(Walk.capabilities["video.write.passthrough"] == "0.9.0")
    #expect(!Walk.notImplemented.contains("video.write.passthrough"))
    #expect(Walk.notImplementedReasons["video.write.passthrough"] == nil)
    #expect(Walk.capabilities["video.write.reencode"] == "0.3.0", "the re-encode path is unchanged")
}

@Test func theMismatchErrorNamesTheNumbers() {
    let e = WalkVideoError.frameCountMismatch(requested: 100, decodable: 78, url: URL(fileURLWithPath: "/seg.mov"))
    #expect(e.description.contains("100 frames requested"))
    #expect(e.description.contains("78 decodable"))
    #expect(e.description.contains("22 missing"))
    #expect(e.description.hasPrefix("FRAME COUNT MISMATCH"))
}
