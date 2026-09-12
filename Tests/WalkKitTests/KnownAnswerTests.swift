import Testing
import Foundation
import CoreMedia
@testable import WalkKit

// THE KNOWN-ANSWER TEST. This is the one that matters.
//
// Reference values come from decision #495, where full-resolution
// `ffmpeg signalstats` and an AVAssetReader Y-plane pass agreed to three
// decimals on 33 of 33 frames. They are the numbers the engine must keep
// producing, and they are the reason 0.3.0's reader port was verified rather
// than assumed.
//
// THE MATERIAL IS NOT IN THE REPOSITORY and cannot be: it is 780 MB of the
// operator's archive on an external volume. So these tests are conditional, and
// that is a real hole in CI which the README names rather than hides. A skipped
// test is reported by swift-testing as skipped, so the absence is visible in the
// log instead of passing silently.

enum KnownAnswer {
    static let clipPath =
        "/Volumes/NVMeExt1/Content/Photography/Digital Negatives/storm/DJI_20260912051637_0012_D.MP4"

    static var url: URL { URL(fileURLWithPath: clipPath) }
    static var available: Bool { FileManager.default.fileExists(atPath: clipPath) }

    /// 10-bit Y code means, full resolution, stride 1. Decision #495.
    static let yMeans: [Int: Double] = [
        2334: 427.783,   // found by Core Image, MISSED by the 640-wide ffmpeg pass
        2340: 420.763,   // likewise
        2346: 414.176,   // the baseline neighbour
        2347: 439.098,   // the brightest strike in the clip
        2348: 413.062,   // the dark frame immediately after
        2352: 426.450,
        2356: 422.966,
        2359: 419.040,
    ]

    /// The six strikes decision #495 established for this clip.
    static let sixStrikes = [2334, 2340, 2347, 2352, 2356, 2359]

    /// Vision confidences, measured on the shipped taxonomy with no model file.
    static let lightning: [Int: Double] = [2347: 0.3435, 2348: 0.0129]
}

@Test(.enabled(if: KnownAnswer.available),
      .timeLimit(.minutes(5)))
func frame2347MeasuresExactly439Point098() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)

    // The clip must be what the references were taken on, or the numbers mean
    // nothing. Checked rather than assumed.
    #expect(reader.info.width == 3840 && reader.info.height == 2160)
    #expect(reader.info.codec == "hvc1")
    #expect(reader.info.bitDepth == 10)
    #expect(reader.info.frameDuration == CMTimeMake(value: 1001, timescale: 60000))
    #expect(reader.info.isHLGBT2020)

    let series = try await FrameScanner.scan(
        reader, options: .init(frames: 2328..<2362, computeYPlane: true, yPlaneStride: 1))

    for (frame, reference) in KnownAnswer.yMeans.sorted(by: { $0.key < $1.key }) {
        let sample = try #require(series.sample(at: frame),
                                  "frame \(frame) was not delivered by the scan")
        let measured = try #require(sample.yMean, "frame \(frame) carries no Y-plane measurement")
        // The references are quoted to three decimals, so agreement to within
        // half of the last place is exact agreement.
        #expect(abs(measured - reference) < 0.001,
                "frame \(frame): measured \(measured), #495 reference \(reference)")
    }

    // 10-bit specifically. The tags do not prove this — #495 measured every
    // HLG/BT.2020 attachment surviving an 8-bit buffer — so the Y plane does.
    let strike = try #require(series.sample(at: 2347))
    #expect(strike.yMax == 1007, "peak headroom is the real reason to pin 10-bit")
    #expect(strike.yClipped == false, "at 8 bits this frame clips at 255; at 10 bits it does not")
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(10)))
func theScanFindsAllSixKnownStrikes() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)
    let series = try await FrameScanner.scan(reader)
    #expect(series.decodedFrames == 2771, "decoded frame count, measured; #495 reports the same")
    #expect(series.missingIndices.isEmpty, "no frame index inside the span may go undelivered")

    let result = EventDetector().detect(series)
    let found = Set(result.events.map(\.index))
    for strike in KnownAnswer.sixStrikes {
        #expect(found.contains(strike),
                "frame \(strike) is a confirmed strike and the detector must not miss it")
    }
    // The detector is allowed to flag MORE than the six — and does, 13 in total.
    // It is not allowed to flag half the clip.
    #expect(result.events.count < 40,
            "13 candidates over 2771 frames is triage; hundreds would be noise")
    #expect(result.boundBy == .floor,
            "on this clip the statistical threshold is 0.301% and the 1% floor binds — measured")
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
func visionSeparatesTheStrikeFromItsDarkNeighbour() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)
    let classifier = Classifier()
    var measured = [Int: Double]()
    for frame in [2347, 2348] {
        let f = try await reader.frame(at: frame)
        measured[frame] = try await classifier.classify(f).confidence("lightning")
    }
    for (frame, reference) in KnownAnswer.lightning {
        let m = try #require(measured[frame])
        #expect(abs(m - reference) < 0.001,
                "frame \(frame): lightning \(m), #495 reference \(reference)")
    }
    let ratio = (measured[2347] ?? 0) / max(measured[2348] ?? 1, 1e-9)
    #expect(ratio > 20, "the separation between a strike and its neighbour was 27x; got \(ratio)x")
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(10)))
func aOneFrameEventSurvivesA60To30Conform() async throws {
    // The whole point of retiming by scaling rather than dropping: a one-frame
    // strike must still be there afterwards. Source frame 2347 becomes output
    // frame 47 and must still measure 439.098 to within the re-encode delta.
    let reader = try await VideoReader(url: KnownAnswer.url)
    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-knownanswer-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: out) }

    let report = try await VideoWriter().write(reader, frames: 2300..<2400, to: out)
    #expect(report.framesAppended == 100)
    #expect(report.framesDecodable == 100, "the readback control: appended must equal decodable")
    #expect(report.verified)
    #expect(report.retimeRatio == (2000, 1001), "60→30 on 1001/60000 is exactly 2000/1001")
    #expect(abs(report.outputFrameRate - 30.0) < 0.01,
            "a truncated ratio gave 31.58 fps and every other check still passed")
    #expect(abs(report.outputSeconds - 100.0 / 30.0) < 0.01)
    #expect(report.codec == "hvc1")
    #expect(report.bitDepth == 10)
    #expect(report.transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String),
            "HLG must survive the round trip")
    #expect(report.colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))

    let back = try await VideoReader(url: out)
    let series = try await FrameScanner.scan(
        back, options: .init(frames: 45..<50, computeYPlane: true))
    let landed = try #require(series.sample(at: 47)?.yMean,
                              "source frame 2347 must land at output frame 47")
    let delta = abs(landed - 439.098) / 439.098
    #expect(delta < 0.0001, "measured round-trip delta was 0.0044%; got \(delta * 100)%")
}

@Test(.enabled(if: !KnownAnswer.available))
func theKnownAnswerMaterialIsAbsentAndThatIsReported() {
    // This test EXISTS TO RUN IN CI, where the archive volume is not mounted.
    // It passes, loudly, so the log carries the fact that the known-answer tests
    // above did not execute. A green CI run on this repository does NOT mean the
    // six-frame known answer was checked.
    print("""

          ================================================================
          KNOWN-ANSWER TESTS DID NOT RUN.
          \(KnownAnswer.clipPath) is not present.
          The six-strike detection, the 439.098 Y-plane measurement, the
          Vision separation and the 60→30 retime round trip were ALL SKIPPED.
          This run proves the pure-arithmetic paths only.
          ================================================================

          """)
    #expect(!KnownAnswer.available)
}
