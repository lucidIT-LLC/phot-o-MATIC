import Testing
import Foundation
import CoreMedia
import CoreGraphics
import ImageIO
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

// TASK #764 -- GROUPED, NOT SERIALIZED. These are the eleven tests that open a
// VideoReader.Pass against the storm clip and relied on `.timeLimit` as their
// only bound -- the exact set that starved the cooperative pool before
// ReadExecutor.swift moved the read off it (see ReadExecutorTests.swift). The
// production fix removed the need to serialize them: ReadExecutor is a
// concurrent, overcommitting DispatchQueue, so N simultaneous passes no longer
// contend for a fixed-width pool the way N cooperative threads on hw.ncpu cores
// did. This suite exists as the CONTAINER that gap was missing -- prior to it
// there was nowhere to write `.serialized` if these ever needed it again. If a
// future regression reintroduces cooperative-pool starvation, add
// `@Suite(.serialized)` here rather than reaching for `--no-parallel`.
@Suite("Known-answer video material (task #764)")
struct KnownAnswerVideoTests {
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


    // MARK: - 0.4.0: the shared orchestration must not change a number

    // THE CLAIM 0.4.0 MAKES IS THAT NOTHING MOVED. `ClipScan` gathered a sequence
    // that existed three times over — in the CLI, in the app, and about to be a
    // third time in the MCP server — and the MCP surface is a wrapper over it. A
    // wrapper that quietly re-derives a value is not a wrapper, so this asserts the
    // known answer THROUGH the new path rather than only through FrameScanner.

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
    func clipScanReturnsTheSameKnownAnswerAsTheDirectPath() async throws {
        var options = ClipScan.Options(frames: 2328..<2362, computeYPlane: true, yPlaneStride: 1)
        options.thumbnailDirectory = nil          // measured here, not pictured
        let result = try await ClipScan.run(KnownAnswer.url, options: options)

        // Frame 2347's Y mean is the reference value, to the rounding of the
        // three-decimal reference itself.
        let strike = try #require(result.candidates.first { $0.frame == 2347 })
        let y = try #require(strike.yMean)
        #expect(abs(y - KnownAnswer.yMeans[2347]!) < 0.001,
                "ClipScan reported \(y) for frame 2347; the reference is \(KnownAnswer.yMeans[2347]!)")

        // And the Vision confidence, through the same path.
        let lightning = try #require(strike.confidence("lightning"))
        #expect(abs(lightning - KnownAnswer.lightning[2347]!) < 0.01)

        // Every one of #495's six strikes is still a candidate.
        let frames = Set(result.candidates.map(\.frame))
        for expected in KnownAnswer.sixStrikes {
            #expect(frames.contains(expected), "strike at frame \(expected) was not found")
        }

        // yMeanIsExact is what the MCP surface reports off `yPlaneStride`. At stride
        // 1 it must be true, or a consumer will compare an approximation against a
        // reference and conclude the engine drifted.
        #expect(result.yPlaneStride == 1)
        #expect(result.classified)
    }

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
    func aThumbnailIsWrittenAndIsAPictureNotAMeasurement() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-thumbs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var options = ClipScan.Options(frames: 2344..<2350, computeYPlane: false, yPlaneStride: 1)
        options.classify = false
        options.thumbnailDirectory = dir
        options.thumbnailMaxWidth = 320
        let result = try await ClipScan.run(KnownAnswer.url, options: options)

        let strike = try #require(result.candidates.first { $0.frame == 2347 })
        let thumb = try #require(strike.thumbnail)
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        #expect(thumb.lastPathComponent.contains("f002347"),
                "the filename must name the frame, or a path handed back cannot be traced to a row")

        // It is a real PNG at the width asked for, and it is NOT where any number
        // came from — classification was off and no Y plane was read, yet the
        // candidate still carries its luminance measurements.
        let source = try #require(CGImageSourceCreateWithURL(thumb as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320)
        #expect(strike.confidences == nil, "classification was off; that must read as null, never as zero")
        #expect(strike.yMean == nil)
        #expect(strike.ciLuma > 0)
    }

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(10)))
    func aFolderWalkOverTheStormClipsFindsEachClipSeparately() async throws {
        let folder = KnownAnswer.url.deletingLastPathComponent()
        // Two clips only: this asserts the folder path, not the whole archive.
        var options = ClipScan.Options.triage()
        options.classify = false
        options.frames = 0..<120
        let result = try await ClipScan.folder([folder],
                                               find: .init(recursive: false, maximumClips: 2),
                                               options: options)
        #expect(result.found.clips.count == 2)
        #expect(result.clips.count == 2)
        #expect(result.failures.isEmpty)
        #expect(result.totalFramesScanned > 0)
        // The .JPG, .DNG and .SRT sidecars sitting beside the clips must be skipped,
        // not attempted. A folder walk that tries to decode a sidecar reports a
        // failure the operator has to interpret.
        #expect(!result.found.skipped.isEmpty)
        #expect(result.found.skipped.allSatisfy {
            !ClipFinder.videoExtensions.contains($0.pathExtension.lowercased())
        })
    }

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(5)))
    func aSubRangeScanDoesNotInventAHandleShortfall() async throws {
        // THE DEFECT THIS TEST PINS. Scanning frames 2300–2400 of clip 0012 and
        // asking for one-second handles reported "tail short 0.099 s (asked 1.00,
        // clip offered 0.901)". The clip has ~2771 frames and a full second after
        // frame 2388 is entirely available — the shortfall was the SCAN WINDOW,
        // reported as though it were the clip. Found by reading back a written
        // segment, not by reasoning about the code.
        var options = ClipScan.Options(frames: 2300..<2400, computeYPlane: false)
        options.classify = false
        let scanned = try await ClipScan.run(KnownAnswer.url, options: options)

        let clamp = scanned.segmentClamp
        #expect(!clamp.measured, "a sub-range scan cannot have measured the clip's length")
        #expect(clamp.basis.contains("container estimate"))
        #expect(clamp.totalFrames > 2500,
                "the clamp must be the clip's length (~2771), not the window's (100); it was \(clamp.totalFrames)")

        let builder = SegmentBuilder(totalFrames: clamp.totalFrames,
                                     frameDuration: scanned.info.frameDuration)
        let segments = builder.segments(forEventFrames: scanned.candidates.map(\.frame),
                                        leadSeconds: 1.0, tailSeconds: 1.0)
        #expect(!segments.isEmpty)
        for s in segments {
            #expect(!s.isShort,
                    "segment at event \(s.eventIndex) reports \(s.shortfallNote) — the clip can supply these handles")
        }
    }

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(10)))
    func aWholeClipScanClampsAgainstWhatItMeasured() async throws {
        // The other half, and the reason the original comment was right for its
        // case: over a whole clip the decoded count is a measurement, and the
        // container's arithmetic is not.
        var options = ClipScan.Options.triage()
        options.classify = false
        options.thumbnailDirectory = nil
        let scanned = try await ClipScan.run(KnownAnswer.url, options: options)
        let clamp = scanned.segmentClamp
        #expect(clamp.measured)
        #expect(clamp.basis.contains("measured"))
        #expect(clamp.totalFrames == max(scanned.decodedFrames,
                                         (scanned.candidates.map(\.frame).max() ?? 0) + 1))
        // The container says ~2771; the decode is what counts.
        #expect(abs(clamp.totalFrames - scanned.info.estimatedFrameCount) < 10,
                "decoded \(clamp.totalFrames) against an estimate of \(scanned.info.estimatedFrameCount)")
    }

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(2)))
    func aCancelledScanStopsDecodingRatherThanFinishing() async throws {
        // THE CLAIM THIS TEST EXISTS TO KEEP HONEST. 0.4.1's own commit message
        // said "notifications/cancelled actually cancels". MEASURED, it did not:
        // the cancellation was received and registered, the task flag was set, and
        // the decoder ran to the end of a 15,367-frame clip, because the only
        // checkCancellation in the path sat in ClipScan's candidate loop — after
        // the scan. Acknowledged and nothing stopped.
        //
        // FrameScanner now checks per frame. After the fix, work stopped 30 ms
        // after the cancellation arrived.
        let task = Task { () -> Int in
            var options = ClipScan.Options.triage()
            options.classify = false
            options.thumbnailDirectory = nil
            let r = try await ClipScan.run(KnownAnswer.url, options: options)
            return r.decodedFrames
        }
        // Long enough that the scan is genuinely running, far short of the ~30 s a
        // whole-clip scan of this material takes.
        try await Task.sleep(for: .milliseconds(600))
        let started = ContinuousClock.now
        task.cancel()
        let outcome = await task.result
        let elapsed = ContinuousClock.now - started

        switch outcome {
        case .success(let frames):
            Issue.record("the scan ran to completion after being cancelled — \(frames) frames decoded")
        case .failure(let error):
            #expect(error is CancellationError,
                    "a cancelled scan must fail with CancellationError, not \(error)")
        }
        // The point is that it STOPS, not merely that it reports. A whole-clip scan
        // of this material is about 30 s; anything under a second is a real stop.
        #expect(elapsed < .seconds(2),
                "took \(elapsed) to stop after cancel — cancellation is being noticed too late to matter")
    }

    // MARK: - the teaching spine, checked against the instrument

    @Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(10)))
    func theLuminanceLessonQuotesTheEnginesOwnNumbers() async throws {
        // TASK #740's LAST OWED EDIT, AND THE REASON IT IS A TEST AND NOT AN EDIT.
        //
        // `Coaching.luminanceIsNotLightning` is the one judgment Walk makes without
        // a criteria file, on the grounds that it is Walk's OWN MEASUREMENT rather
        // than anyone's taste. That grounding is a claim about provenance, and until
        // this test existed nothing checked it: the numbers were prose, maintained
        // by hand, and #740 required them to come FROM THE ENGINE rather than from a
        // decision record.
        //
        // MEASURED 2026-09-12, and this is what the test caught. The lesson quoted
        // frame 2388's Y-plane rise as 0.79%, as do four other surfaces. The engine
        // says +0.87% (0.8655%) against its own local-median baseline. 0.79% is
        // frame 2388 divided by frame 2387 ALONE (+0.7933%) — a different baseline
        // rule than the detector uses, which nothing in the engine computes and no
        // reader could have known was in play. It went unnoticed because the pair it
        // travelled with agrees under BOTH rules: 2347 reads +6.02% either way
        // (median +6.0204%, previous frame +6.0172%), so a self-consistent-looking
        // pair carried a number off a rule the engine does not apply.
        //
        // Every figure in the lesson is therefore re-derived here from a scan, and
        // the prose must contain the engine's rendering of it.
        let reader = try await VideoReader(url: KnownAnswer.url)
        var options = FrameScanner.Options(frames: nil, computeYPlane: true)
        options.yPlaneStride = 1   // the Y mean is stride-dependent; see FrameScanner.Options
        let series = try await FrameScanner.scan(reader, options: options)

        let lesson = Coaching.luminanceIsNotLightning

        // WHAT THE ENGINE SAYS, collected first; the prose is judged against it
        // afterwards in BOTH DIRECTIONS. `contains` alone is not enough and the
        // first draft of this test proved it: the detail mentions the Y-plane
        // figure TWICE, so changing one mention to the wrong 0.79% still satisfied
        // a containment check and the test passed on prose it was written to
        // reject. A test that can only detect the LAST wrong number is the same
        // defect it is guarding, one level up. So every number-shaped token in the
        // detail must be one the engine produced, and every number the engine
        // produced must appear.
        var enginePercentages = Set<String>()
        var engineConfidences = Set<String>()

        // 1. The linear rises, in the space the detector actually measures.
        let linear = EventDetector().detect(series)
        for frame in [2347, 2388] {
            let event = try #require(linear.events.first { $0.index == frame },
                                     "frame \(frame) is no longer a candidate at all; the lesson is built on it being one")
            enginePercentages.insert(String(format: "%+.2f%%", event.relativeRise * 100))
        }

        // 2. The Y-plane rise, from the SAME detector on the engine's own Y means,
        //    so the baseline rule is the engine's and not this test's arithmetic.
        //    The floor is lowered and merging switched off for one reason: at the
        //    shipped 1% floor frame 2388 is NOT an event on this plane, which is
        //    itself the lesson, asserted below.
        let yMeans = series.samples.map { $0.yMean ?? .nan }
        let holes = yMeans.filter(\.isNaN).count
        #expect(holes == 0, "\(holes) Y means are missing; the Y-plane figure would be measured on a hole")
        let yPlane = EventDetector(options: .init(minimumRelativeRise: 0.001, mergeWithin: 0))
            .detect(values: yMeans, indices: series.indices, times: series.samples.map(\.time))
        for frame in [2347, 2388] {
            let event = try #require(yPlane.events.first { $0.index == frame })
            enginePercentages.insert(String(format: "%+.2f%%", event.relativeRise * 100))
        }

        // 3. THE CLAIM THAT CARRIES THE LESSON, not just its numbers: on the
        //    gamma-encoded plane the higher-confidence frame is not a candidate.
        let yPlaneAsShipped = EventDetector()
            .detect(values: yMeans, indices: series.indices, times: series.samples.map(\.time))
        #expect(!yPlaneAsShipped.events.contains { $0.index == 2388 },
                "the lesson states 2388 is under the 1% floor on the Y plane; the engine now reports it as an event there")
        #expect(yPlaneAsShipped.events.contains { $0.index == 2347 },
                "2347 must still clear the floor on the Y plane, or the contrast the lesson draws is gone")

        // 4. The confidences, classified now rather than quoted from #495.
        let classifier = Classifier()
        for frame in [2347, 2388] {
            let picture = try await reader.frame(at: frame)
            let confidence = try await classifier.classify(picture).confidence("lightning")
            engineConfidences.insert(String(format: "%.4f", confidence))
        }

        // 5. THE PROSE, JUDGED BOTH WAYS.
        //
        //    A signed percentage to two decimals, and a bare four-decimal fraction,
        //    are the two number shapes this lesson trades in. The "1% floor" and
        //    "a tenth of the brightness" carry no decimal and no sign, so they are
        //    deliberately outside both patterns — they are claims about the engine
        //    checked in section 3 above, not readings off it.
        let quotedPercentages = Set(lesson.detail.matches(of: /[+-][0-9]+\.[0-9]{2}%/).map { String($0.output) })
        // Lookahead only — MEASURED: Swift Regex rejects lookbehind outright with
        // "lookbehind is not currently supported", at compile time, which is the
        // good kind of failure.
        let quotedConfidences = Set(lesson.detail.matches(of: /[0-9]\.[0-9]{4}(?![0-9])/).map { String($0.output) })

        for quoted in quotedPercentages.subtracting(enginePercentages) {
            Issue.record("""
                the lesson quotes \(quoted) and the engine did not measure it. \
                The engine's rises on this clip are \(enginePercentages.sorted()). \
                #740 requires these figures to come FROM THE ENGINE and not from a \
                decision record: 0.79% reached this lesson that way — it is frame \
                2388 against frame 2387 alone, not against the detector's baseline.
                """)
        }
        for quoted in quotedConfidences.subtracting(engineConfidences) {
            Issue.record("the lesson quotes a confidence of \(quoted); the classifier measured \(engineConfidences.sorted())")
        }
        for measured in enginePercentages.subtracting(quotedPercentages) {
            Issue.record("the engine measured \(measured) and the lesson does not say so")
        }
        for measured in engineConfidences.subtracting(quotedConfidences) {
            Issue.record("the classifier measured \(measured) and the lesson does not say so")
        }

        // 6. The spaces must be NAMED. #740's whole finding was a number printed
        //    without the thing that makes it mean anything, and a lesson that
        //    compares 36% to 0.8% without saying they are different quantities
        //    teaches the misreading it exists to prevent.
        #expect(lesson.detail.contains("linear BT.2020"))
        #expect(lesson.detail.contains("gamma-encoded"))
    }
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
