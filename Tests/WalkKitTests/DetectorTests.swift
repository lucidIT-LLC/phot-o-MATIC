import Testing
import CoreMedia
@testable import WalkKit

// The detector on plain numbers. These run anywhere, including CI, which has no
// video. Every one of them can fail.

private func flat(_ n: Int, _ v: Double = 0.4) -> [Double] { Array(repeating: v, count: n) }

@Test func aFlatSeriesFindsNothingAndSaysSo() {
    let r = EventDetector().detect(values: flat(200))
    #expect(r.foundNothing, "a series with no variation must not produce events")
    #expect(r.events.isEmpty)
    #expect(r.verdict.contains("nothing found"),
            "the detector must be able to report an absence in words, not only as an empty array")
}

@Test func theFloorIsWhatMakesNothingFoundReachable() {
    // A purely statistical threshold cannot return an empty answer: scale the
    // bar to the clip's own noise and a heavy-tailed noise distribution still
    // puts frames past it. This is a series with REAL noise (so the robust
    // scale is non-zero) and NO event. The statistical half flags some of the
    // noise; the floor is what returns nothing.
    // Heavy-tailed, which is what real footage looks like: a very quiet floor
    // with occasional larger excursions from cloud motion and exposure drift.
    // Uniform noise will NOT reproduce this — its tails are bounded and 12σ sits
    // outside them, which is how this test first failed.
    var values = [Double]()
    var seed: UInt64 = 0x5DEECE66D
    for i in 0..<600 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u = Double(seed >> 11) / Double(1 << 53)          // [0,1)
        var v = 0.4 * (1.0 + (u - 0.5) * 0.00002)             // ±0.001% floor
        if i % 23 == 0 { v += 0.4 * 0.003 }                   // +0.3% excursion
        values.append(v)
    }

    let withFloor = EventDetector().detect(values: values)
    var noFloor = EventDetector.Options(); noFloor.minimumRelativeRise = 0
    let without = EventDetector(options: noFloor).detect(values: values)

    #expect(without.robustSigma > 0, "the series must carry a measurable noise scale for this to be a fair test")
    #expect(without.boundBy == .statistics, "with the floor at zero only the statistics can bind")
    #expect(!without.events.isEmpty,
            "pure statistics flag noise as events — which is exactly why the floor exists")
    #expect(withFloor.foundNothing, "0.03% noise is far below the 1% floor and must come back empty")
    #expect(withFloor.boundBy == .floor)
}

@Test func aSeriesWithNoMeasurableVariationRefusesRatherThanFlagEverything() {
    // MEASURED on real footage, 2026-09-12: on storm clips 0010 and 0011 the
    // MAD-derived scale collapses to exactly zero. With the floor removed a
    // zero threshold would flag every frame at or above its own local median —
    // about half the clip. Inability to measure must not present as detection.
    var opts = EventDetector.Options(); opts.minimumRelativeRise = 0
    let r = EventDetector(options: opts).detect(values: flat(300))
    #expect(r.scaleCollapsed)
    #expect(r.threshold <= 0)
    #expect(r.foundNothing, "a zero threshold must produce no events, not 150 of them")
    #expect(r.verdict.contains("cannot be determined"))
}

@Test func aSingleFrameSpikeIsFound() {
    var values = flat(200)
    values[100] = 0.4 * 1.36            // the size of the measured strike on clip 0012
    let r = EventDetector().detect(values: values)
    #expect(r.events.count == 1)
    #expect(r.events.first?.index == 100)
    #expect(abs((r.events.first?.relativeRise ?? 0) - 0.36) < 0.01)
}

@Test func theStatisticalHalfCatchesWhatAConstantMisses() {
    // The 0.2.0-era failure this class exists to prevent: a fixed threshold on a
    // downscaled pass missed frames 2334 and 2340 of clip 0012. Here the clip's
    // own noise is 20x smaller than the floor, so a 0.15% event is real for THIS
    // clip and a 1% constant would discard it. The statistical half must bind.
    var values = flat(400, 1.0)
    for i in 0..<400 { values[i] += Double((i * 37) % 5) * 0.00001 }   // ~0.005% noise
    values[200] = 1.0 + 0.0015                                        // +0.15%
    var opts = EventDetector.Options()
    opts.minimumRelativeRise = 0.0001   // a clip-appropriate floor, not the 1% default
    let r = EventDetector(options: opts).detect(values: values)
    #expect(r.boundBy == .statistics, "on a very quiet clip the statistics must set the bar")
    #expect(r.events.map(\.index).contains(200))

    // And the default 1% floor would have thrown it away — the honest limit,
    // asserted rather than described.
    let defaulted = EventDetector().detect(values: values)
    #expect(defaulted.foundNothing,
            "the 1% default floor discards a real 0.15% event; that trade is named in Options")
}

@Test func adjacentCandidatesCollapseToTheirPeak() {
    var values = flat(100)
    values[50] = 0.4 * 1.10
    values[51] = 0.4 * 1.30      // the peak
    values[52] = 0.4 * 1.05
    let r = EventDetector().detect(values: values)
    #expect(r.events.count == 1, "one flash spanning three frames is one event")
    #expect(r.events.first?.index == 51, "the event is reported at its peak")
    #expect(r.events.first?.mergedFrames == 3)
    #expect(r.candidatesBeforeMerge == 3, "the pre-merge count stays visible")
}

@Test func separatedEventsStaySeparate() {
    var values = flat(200)
    values[50] = 0.4 * 1.3
    values[60] = 0.4 * 1.3
    let r = EventDetector().detect(values: values)
    #expect(r.events.count == 2)
    #expect(r.events.map(\.index) == [50, 60])
}

@Test func theBaselineExcludesTheFrameUnderTest() {
    // Include the frame in its own baseline and a bright frame partly hides
    // itself. 17 samples with the spike included would pull the median up.
    var values = flat(60)
    values[30] = 0.4 * 2.0
    let r = EventDetector().detect(values: values)
    #expect(abs((r.events.first?.baseline ?? 0) - 0.4) < 1e-12,
            "the baseline must be the neighbours, not the neighbours plus the event")
}

@Test func aTooShortSeriesIsRefusedNotGuessed() {
    let r = EventDetector().detect(values: [0.4, 0.5])
    #expect(r.foundNothing)
    #expect(r.framesConsidered == 2)
}

// MARK: - SegmentBuilder

private let fd6094 = CMTimeMake(value: 1001, timescale: 60000)

@Test func handlesAreAppliedBothSides() {
    let b = SegmentBuilder(totalFrames: 2771, frameDuration: fd6094, coalesceOverlapping: false)
    let s = b.segments(forEventFrames: [1000], leadSeconds: 1.0, tailSeconds: 1.0)
    #expect(s.count == 1)
    #expect(s[0].startFrame == 940)           // 1.0 s at 59.94 fps = 60 frames
    #expect(s[0].endFrame == 1061)
    #expect(!s[0].isShort)
    #expect(s[0].shortfallNote == "full handles")
}

@Test func aShortfallIsReportedNotSilentlyClamped() {
    // THE REAL CONSTRAINT: an event 0.70 s into a 16.2 s clip has 0.70 s of
    // lead-in available and no more.
    let frames = Int((16.2 / CMTimeGetSeconds(fd6094)).rounded())
    let event = Int((0.70 / CMTimeGetSeconds(fd6094)).rounded())
    let b = SegmentBuilder(totalFrames: frames, frameDuration: fd6094)
    let s = b.segments(forEventFrames: [event], leadSeconds: 2.0, tailSeconds: 2.0)
    #expect(s.count == 1)
    #expect(s[0].startFrame == 0, "it must clamp at the start of the clip")
    #expect(s[0].isShort, "and it must SAY it clamped")
    #expect(abs(s[0].leadSeconds - 0.70) < 0.02)
    #expect(abs(s[0].leadShortfallSeconds - 1.30) < 0.02)
    #expect(s[0].tailShortfallSeconds == 0, "the tail had room; only the lead was short")
    #expect(s[0].shortfallNote.contains("lead short"))
    #expect(s[0].requestedLeadSeconds == 2.0,
            "what was ASKED for must survive in the record, or the shortfall is unprovable")
}

@Test func aTailShortfallAtTheEndOfAClipIsReported() {
    let b = SegmentBuilder(totalFrames: 100, frameDuration: fd6094)
    let s = b.segments(forEventFrames: [95], leadSeconds: 0.1, tailSeconds: 2.0)
    #expect(s[0].endFrame == 100)
    #expect(s[0].isShort)
    #expect(s[0].tailShortfallSeconds > 1.9)
    #expect(s[0].shortfallNote.contains("tail short"))
}

@Test func overlappingSegmentsCoalesce() {
    let b = SegmentBuilder(totalFrames: 2771, frameDuration: fd6094)
    let s = b.segments(forEventFrames: [2347, 2352, 2356], leadSeconds: 1.0, tailSeconds: 1.0)
    #expect(s.count == 1, "three strikes within 0.15 s must not produce three near-identical files")
    #expect(s[0].startFrame == 2287)
    #expect(s[0].endFrame == 2417)
}

@Test func coalescingCanBeTurnedOff() {
    let b = SegmentBuilder(totalFrames: 2771, frameDuration: fd6094, coalesceOverlapping: false)
    let s = b.segments(forEventFrames: [2347, 2352, 2356], leadSeconds: 1.0, tailSeconds: 1.0)
    #expect(s.count == 3)
}

@Test func theEventFrameItselfIsAlwaysInsideTheSegment() {
    let b = SegmentBuilder(totalFrames: 2771, frameDuration: fd6094)
    for handles in [0.0, 0.1, 1.0, 5.0] {
        let s = b.segments(forEventFrames: [1500], leadSeconds: handles, tailSeconds: handles)
        #expect(s[0].frames.contains(1500),
                "a zero-handle segment must still contain the frame it is about")
    }
}

// MARK: - retime arithmetic

@Test func theRetimeRatioIsExactIntegerArithmetic() {
    // MEASURED DEFECT, 2026-09-12: computing this through a Double truncated
    // 2000/1001 to 1999/1001. Every frame landed, readback verified, and the
    // output came back 3.3317 s at 31.58 fps instead of 3.3333 s at 30.00.
    // A wrong answer that passes every check except reading the duration.
    let timescale = Int32(60000), value = Int32(1001)
    var num = timescale, den = Int32(30) * value
    let g = VideoWriter.gcd(num, den); num /= g; den /= g
    #expect(num == 2000 && den == 1001, "60→30 on a 1001/60000 source is exactly 2000/1001")

    let viaDouble = Int32((1.0 / 30.0) / (Double(value) / Double(timescale)) * 1001.0)
    #expect(viaDouble == 1999, "and this is the wrong answer the Double path produced")
    #expect(viaDouble != num)
}

@Test func retimeIsExactForCommonRates() {
    for (ts, val, fps, expect) in [(Int32(60000), Int32(1001), Int32(30), (2000, 1001)),
                                   (Int32(60000), Int32(1001), Int32(60), (1000, 1001)),
                                   (Int32(30000), Int32(1001), Int32(30), (1000, 1001)),
                                   (Int32(600),   Int32(10),   Int32(30), (2, 1))] {
        var n = ts, d = fps * val
        let g = VideoWriter.gcd(n, d); n /= g; d /= g
        #expect(Int(n) == expect.0 && Int(d) == expect.1,
                "\(ts)/\(val) -> \(fps) fps should be \(expect.0)/\(expect.1), got \(n)/\(d)")
    }
}
