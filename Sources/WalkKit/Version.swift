import Foundation

/// Walk's version and capability contract.
///
/// This exists because of a defect class this factory keeps finding: prose
/// describing code, the code changing, and nothing detecting the drift. Retired
/// KB numbers cited as live authority. A rule naming a connection that had been
/// renamed. Pixel 2.2.0 shipping a reversed sign that passed every verifier.
/// In each case a document described a mechanism that no longer existed, and
/// there was no mechanical way to notice.
///
/// A consumer — Andy's skill, the MCP server, an app — is written against a
/// specific Walk. `Contract.check(expecting:)` lets it FAIL LOUDLY rather than
/// proceed on stale instructions.
///
/// 0.4.0 ADDED `notImplementedReasons` BECAUSE THE LIST ITSELF DRIFTED.
/// Decision #507: the operator dropped a folder into Walk.app, it walked eight
/// clips, and `ingest.dump` was sitting in `notImplemented` the whole time. The
/// bare name was doing two jobs — "enumerate a folder and scan each clip", which
/// the app did and the library did not declare, and "go through my dump for me",
/// which nothing does. A one-word entry cannot distinguish those, so it was read
/// as false when it was half true. Every absent capability now carries a reason,
/// and a test fails if one does not.
public enum Walk {
    // 0.5.6 IS SKIPPED ON PURPOSE. The operator does not use six in a version
    // number, which is a standing preference and not a defect to correct. Noted
    // here rather than left as an unexplained gap, because an unexplained gap in
    // a version sequence is exactly the sort of thing a later session
    // "corrects."
    public static let version = "0.9.0"

    /// Capabilities a consumer may rely on, each with the version that
    /// introduced it. A consumer naming a capability absent from this list is
    /// describing something Walk does not do.
    public static let capabilities: [String: String] = [
        "hlg.sdr.transform":     "0.1.0",  // BT.2100 inverse OETF + OOTF + BT.2020→709
        "hlg.systemGamma":       "0.1.0",  // BT.2390 derivation from target nits
        "grade.filmic":          "0.1.0",  // Hable tone map
        "measure.mean":          "0.1.0",  // whole-image channel means, managed
        "measure.meanRaw":       "0.1.0",  // unmanaged file values, CPU reduction
        "measure.castCheck":     "0.1.0",  // channel-spread delta across a grade
        "contract.version":      "0.2.0",  // this surface
        "video.read":            "0.3.0",  // AVAssetReaderOutput.Provider, frame-exact addressing
        "video.yPlane":          "0.3.0",  // 10-bit Y code statistics, left-aligned words
        "video.scan":            "0.3.0",  // per-frame CIAreaAverage luminance time series
        "video.detect":          "0.3.0",  // events from the clip's own statistics + a named floor
        "video.segment":         "0.3.0",  // cut ranges with handles; shortfall reported, not clamped
        "video.retime":          "0.3.0",  // exact integer-rational timestamp scaling
        "video.write.reencode":  "0.3.0",  // HEVC Main10 + HLG, readback-verified frame count
        "video.trim":            "0.3.0",  // a frame range out to its own file
        "classify.vision":       "0.3.0",  // ClassifyImageRequest, 1303-identifier taxonomy, no model file
        "colorspace.linear2020": "0.3.0",  // pinned extendedLinearITUR_2020 working space
        // NOT MOVED, AND THE RESTRAINT IS THE POINT. This is the SwiftUI
        // window that shows DETECTED CANDIDATES, and 0.5.5 did not change it.
        // The time-sampled sheet added in 0.5.5 is a different thing answering a
        // different question, and it is declared below under its own names. The
        // precedent is #507: `ingest.dump` was one word doing two jobs, and the
        // fix was a name narrow enough to be true, not a name stretched until it
        // covered what had been built.
        "app.proofSheet":        "0.3.0",  // SwiftUI window that shows what the DETECTOR found
        // 0.4.0 — the conversation reaching the engine (#507), and the library
        // taking back the two things the front doors had each grown privately.
        "scan.clip":             "0.4.0",  // one clip end to end: read, scan, detect, classify, thumbnail
        "ingest.folderScan":     "0.4.0",  // enumerate video files in folders and scan each; NOT a sort, see ingest.dump
        "thumbnail.displayPNG":  "0.4.0",  // tone-mapped sRGB PNG per candidate, written to disk
        "grade.still.api":       "0.4.0",  // the 0.1.0 still grade as a library call with its measurements
        "contract.reasons":      "0.4.0",  // every notImplemented entry carries why
        "mcp.stdio":             "0.4.0",  // MCP server over stdio: dual-era, server/discover + initialize
        // 0.5.0 — #513: the output is a COACHING VERDICT, not a readout. The
        // SHAPE and the loader are Walk's; the judgment in them is Andy's,
        // which is why `coach.verdict` is still below in notImplemented.
        "coach.bands":           "0.5.0",  // #513's three bands; band 2's change AND forward question are init-enforced, not requested
        "coach.criteria":        "0.5.0",  // #499's criteria file: four-field rules, own version, staleness check, absence reported as absence
        "coach.evidence":        "0.5.0",  // every verdict carries the measurements that fired it and the decision that established the rule
        // 0.5.5 — "what is in this folder?", which the detector cannot answer.
        // A candidate is a luminance event, so a clip whose light never changes
        // produces no candidates and no picture; MEASURED on the operator's own
        // GoPro folder, two clips of eight. Sampling TIME instead of events
        // gives every clip a picture of its arc. Walk emits the data; the page
        // is a separate artifact, so no renderer is compiled in here.
        "sheet.timeSampled":     "0.5.5",  // N frames per clip spaced evenly across the whole duration, each centered in its slice so none is frame 0; one cell per still
        "sheet.progressive":     "0.5.5",  // the manifest is written before any pixel is decoded and rewritten atomically as cells land, and every cell carries a tiny tone-mapped placeholder inline
        "sheet.manifest":        "0.5.5",  // manifest.json: per item the dimensions, timing, codec, transfer function and the tone map applied; per cell the frame, timecode, seconds, file path and placeholder
        "ingest.stills":         "0.5.5",  // JPG/HEIC/DNG/PNG/TIFF enumerated alongside video, with the video extension set still declared exactly once
        "telemetry.djiSRT":      "0.5.5",  // the sibling .SRT read as a DISTRIBUTION over the whole file, never frame 1, plus a 180-degree shutter comparison against 1/(2 x fps)
        // 0.5.7 — the custom Core ML path, moved out of notImplemented because
        // CODE AND TESTS NOW STAND BEHIND IT and not because the spike succeeded.
        // The old reason said in terms that a spike was not enough; that
        // condition is what changed, not the measurement.
        "coreml.custom":         "0.5.7",  // CustomModel: compile a supplied .mlmodel at RUNTIME via MLModel.compileModel(at:), load it, run it over a frame through VNCoreMLModel; ships no model and names no subjects
        // 0.9.0 — task #721 closes. The 22 "lost" frames were GOP lead-in
        // counted as output; the file always held the frames asked for. The
        // path now sets the session to the requested range, appends in decode
        // order, reads the file back, and fails on any count mismatch.
        "video.write.passthrough": "0.9.0",  // stored bitstream copied, no decode/encode; requested == decodable or WalkVideoError.frameCountMismatch
    ]

    /// What Walk explicitly does NOT do yet. Stated so a consumer cannot infer
    /// capability from silence — absence indistinguishable from success is the
    /// failure mode this factory measures most often.
    ///
    /// Kept as `[String]` so a consumer written against 0.3.0 still compiles;
    /// the why lives in `notImplementedReasons`, which a test requires to be
    /// complete.
    public static let notImplemented: [String] = [
        "video.audio",
        "ingest.dump",
        "ingest.triage",
        "page.bestWorst",
        "touchup",
        "app.drive",
        "fcpxml.export",
        "coach.verdict",
        "coach.stills",
    ]

    /// Why each absent capability is absent, and what exists instead. A
    /// capability list that says only "no" teaches a consumer nothing about
    /// where the edge actually is, which is how `ingest.dump` came to be read as
    /// a flat denial of folder handling.
    public static let notImplementedReasons: [String: String] = [
        "video.audio":
            "#495: audio is never read, retimed or written. A 60→30 retime with audio is a different problem and has not been attempted. Segments come out silent.",
        "ingest.dump":
            "#496's 'go through my dump for me' — RANKING a mixed folder by interest. NOT built, and distinct from ingest.folderScan, which IS built and only enumerates and scans. #507 measured the gap: the detector is a whole-frame luminance rise with a lightning classifier attached, so on non-storm footage a candidate is a brightness change and nothing more — 38 candidates on one GoPro clip are luminance events, not interesting moments. Walking the folder is solved; deciding what is worth keeping is not. 0.5.5 adds sheet.timeSampled, which SHOWS a whole folder — every clip as an evenly-spaced strip, every still as a cell — so the operator can decide. It samples TIME and deliberately orders nothing by interest, so it is a way of looking and still not a sort.",
        "ingest.triage":
            "The general-interest detector #498 needs — more than one event type, so 'give it a folder, get back a sort' means a sort and not a list. Recorded as its own name in 0.4.0 so that ingest.dump stops carrying two meanings at once. Nobody has scoped what 'interesting' means for non-storm material; #507 names that as inferred, not measured.",
        "page.bestWorst":
            "RANKING stills into a best and a worst — not built, and distinct from sheet.timeSampled (0.5.5), which IS built and shows every still in a folder as a cell alongside the clips. The difference is the same one ingest.dump names: showing is solved, ordering by quality is not, and #499 puts that judgment in Andy's criteria file rather than in a metric. A page that put the 'best' frame first would be rendering a verdict the criteria file owns.",
        "touchup":
            "The quick corrections Lightroom does — not built.",
        "app.drive":
            "Walk driving Affinity or Lightroom. The coach's lane (#494 puts actuation outside the engine), and unmeasured here.",
        "fcpxml.export":
            "#493 names FCPXML as the editorial handoff, and #493 also settles the frame a reader is likely to get backwards: Final Cut is REJECTED as a control surface and VALID as a handoff target, so the destination was never in doubt -- only the writer. NO WalkKit CODE EMITS FCPXML. Segments still come out as .mov files only. WHAT CHANGED 2026-09-12 IS THE EVIDENCE UNDER THE ABSENCE, not the absence: the format is no longer an unknown. Final Cut Pro 12.3 ships its own DTDs at Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_0.dtd through v1_14.dtd, which is a better authority than the published page (that page is JS-rendered and returns a title and no body to a fetch). A five-clip timeline over the operator's own 59.94 GoPro selects was generated from AVFoundation-measured durations and validated clean against the shipped FCPXMLv1_13.dtd, with a negative control proving the validator can fail. So this stays absent for a REASON THAT IS NOW NARROW: emitting the file is understood and unbuilt in the library, and the round trip is one-way by design -- FCP's ProEditor.sdef exposes exactly one command, `get`, so an assembly can be handed over and read back but never written through AppleScript. Building this means a WalkKit emitter taking SegmentBuilder ranges to a spine, plus the decision of whether Walk writes whole clips or cut ranges, which nobody has scoped.",
        "coach.verdict":
            "THE JUDGMENT ITSELF, and it is absent because no criteria ship with this build. #513 rules that Walk's output is a coaching verdict — KEEPER / HAS POTENTIAL, WITH THIS / NOT WORTH THE TROUBLE, each with a reason and a next-flight lesson — and #499 rules that Andy's hard-earned logic is what renders it — a Walk that does not carry it is a light meter. Present (see coach.bands, coach.criteria, coach.evidence): the band shape with band 2's change and forward question enforced in the initializer, the versioned criteria loader, the staleness check, and the evidence trail. Absent: any criteria to load. THIS IS A STATEMENT ABOUT THE BUILD, NOT ABOUT THE HOST, and 0.5.7 corrects it for saying otherwise. It read \"Every scan therefore reports coaching.available = false with this reason\" — flatly, of every scan — while the next sentence told the operator to install a criteria set and promised the verdicts would render. Both cannot be true, and the host settled it: with Andy's set installed at the default location this host reports coaching.available = true, criteria 1.2.0, 9 rules, while this entry still correctly said no criteria SHIP. A consumer reading the contract was told its coaching was dark at the moment it was lit. So, precisely: coaching.available is HOST state, and it is false only while no matching criteria set is installed; this entry is BUILD state, and it stays here until a set ships inside Walk (Coaching.shippedCriteriaJSON, still nil, tied to this entry by a test in both directions). app.proofSheet DISPLAYS candidates and does not judge them. Install a criteria set at ~/Library/Application Support/Walk/criteria.json, or name one in WALK_CRITERIA, and the verdicts render from it. This entry moves out of the list when a criteria set ships with Walk, and a test fails if one ships while it is still here.",
        "coach.stills":
            "A COACHING VERDICT ON A PHOTOGRAPH, and it is absent because the coach cannot read one — not because nobody wrote rules. Walk MEASURES stills (grade.still.api, measure.mean, measure.castCheck) and SHOWS them (sheet.timeSampled, ingest.stills); it cannot judge one. The coach reads a ClipScan.Candidate, and of the seven selectors in Criteria.Measurement exactly ONE transfers to a still with its meaning intact. relativeRise, relativeRisePercent, sigma and mergedFrames are UNDEFINED for a still: every one is derived from temporal neighbours — a local median baseline, a per-clip robust sigma, a count of merged adjacent frames — and a photograph has no neighbours. yMean and yMax are 10-bit Y-plane CODE VALUES read off a planar YCbCr buffer that a still never produces, so reusing those names on a still would be the same units error #740 found. That leaves vision.<identifier>, which is not enough to band a photograph and is not the judgment #499 puts in Andy's hands. MEASURED 2026-09-12, and this is why the obvious path is worse than none: a still hand-built as a Candidate — the only route that exists today — was banded NOT WORTH THE TROUBLE by a rule reading relativeRise atMost 0.01, because the fabricated zero satisfied it. The verdict carried the evidence line `relativeRise measured 0.0, required atMost 0.0100, held true`: a photograph condemned by a measurement that does not exist for it, with an audit trail that looks complete. Building the path is therefore an ENGINE-CONTRACT decision and not an implementation one — Verdict identity is frame/timecode/seconds and `frame` runs through all seven Malformed cases; Candidate's video fields are non-optional so they cannot report `unmeasured` the way a nil confidence does; and what a still should be judged ON has not been scoped (see ingest.triage). That belongs to the operator and to #513. Named here so no consumer reads coach.bands, coach.criteria or coach.evidence as covering photographs.",
    ]

    public struct Check: Sendable {
        public let ok: Bool
        public let actual: String
        public let expected: String
        public let detail: String
    }

    /// Compare a consumer's expected version against the running one.
    ///
    /// Rule: equal is ok. A NEWER Walk than expected is a WARNING, not a pass —
    /// the consumer's instructions were written against older behavior and may
    /// describe a mechanism that has since changed. An OLDER Walk than expected
    /// is a failure: the consumer expects capability that is not present.
    public static func check(expecting expected: String) -> Check {
        let a = parse(version), e = parse(expected)
        guard let a, let e else {
            return Check(ok: false, actual: version, expected: expected,
                         detail: "unparseable version")
        }
        if a == e {
            return Check(ok: true, actual: version, expected: expected,
                         detail: "exact match")
        }
        // Lexicographic compare. Swift has no < for [Int], and reaching for one
        // was a compile error rather than a silent wrong answer — the good kind.
        if isOlder(a, than: e) {
            return Check(ok: false, actual: version, expected: expected,
                         detail: "Walk is OLDER than the consumer expects — capability the consumer relies on may not exist")
        }
        return Check(ok: false, actual: version, expected: expected,
                     detail: "Walk is NEWER than the consumer was written against — its instructions may describe changed behavior and must be re-verified")
    }

    private static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    private static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".").map { Int($0) }
        guard parts.count == 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.map { $0! }
    }
}
