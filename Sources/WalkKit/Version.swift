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
/// A consumer — Pixel's skill, the MCP server, an app — is written against a
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
    public static let version = "0.4.0"

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
        "app.proofSheet":        "0.3.0",  // SwiftUI window that shows what the scan found
        // 0.4.0 — the conversation reaching the engine (#507), and the library
        // taking back the two things the front doors had each grown privately.
        "scan.clip":             "0.4.0",  // one clip end to end: read, scan, detect, classify, thumbnail
        "ingest.folderScan":     "0.4.0",  // enumerate video files in folders and scan each; NOT a sort, see ingest.dump
        "thumbnail.displayPNG":  "0.4.0",  // tone-mapped sRGB PNG per candidate, written to disk
        "grade.still.api":       "0.4.0",  // the 0.1.0 still grade as a library call with its measurements
        "contract.reasons":      "0.4.0",  // every notImplemented entry carries why
        "mcp.stdio":             "0.4.0",  // MCP server over stdio: dual-era, server/discover + initialize
    ]

    /// What Walk explicitly does NOT do yet. Stated so a consumer cannot infer
    /// capability from silence — absence indistinguishable from success is the
    /// failure mode this factory measures most often.
    ///
    /// Kept as `[String]` so a consumer written against 0.3.0 still compiles;
    /// the why lives in `notImplementedReasons`, which a test requires to be
    /// complete.
    public static let notImplemented: [String] = [
        "video.write.passthrough",
        "video.audio",
        "ingest.dump",
        "ingest.triage",
        "page.bestWorst",
        "touchup",
        "app.drive",
        "fcpxml.export",
        "coreml.custom",
    ]

    /// Why each absent capability is absent, and what exists instead. A
    /// capability list that says only "no" teaches a consumer nothing about
    /// where the edge actually is, which is how `ingest.dump` came to be read as
    /// a flat denial of folder handling.
    public static let notImplementedReasons: [String: String] = [
        "video.write.passthrough":
            "Open defect task #721. Every append() returns true, writer.status is completed, writer.error is nil, and the file is 22 frames short. Named here rather than left out, because a capability list silent about a known-broken path is the defect it exists to prevent. VideoWriter re-encodes instead.",
        "video.audio":
            "#495: audio is never read, retimed or written. A 60→30 retime with audio is a different problem and has not been attempted. Segments come out silent.",
        "ingest.dump":
            "#496's 'go through my dump for me' — RANKING a mixed folder by interest. NOT built, and distinct from ingest.folderScan, which IS built and only enumerates and scans. #507 measured the gap: the detector is a whole-frame luminance rise with a lightning classifier attached, so on non-storm footage a candidate is a brightness change and nothing more — 38 candidates on one GoPro clip are luminance events, not interesting moments. Walking the folder is solved; deciding what is worth keeping is not.",
        "ingest.triage":
            "The general-interest detector #498 needs — more than one event type, so 'give it a folder, get back a sort' means a sort and not a list. Recorded as its own name in 0.4.0 so that ingest.dump stops carrying two meanings at once. Nobody has scoped what 'interesting' means for non-storm material; #507 names that as inferred, not measured.",
        "page.bestWorst":
            "The best/worst page for stills — not built.",
        "touchup":
            "The quick corrections Lightroom does — not built.",
        "app.drive":
            "Walk driving Affinity or Lightroom. The coach's lane (#494 puts actuation outside the engine), and unmeasured here.",
        "fcpxml.export":
            "#493 names FCPXML as the editorial handoff. Untouched; segments come out as .mov files only.",
        "coreml.custom":
            "#495: whether a custom .mlmodel compiles and loads without Xcode is open, and task #722 stands. classify.vision uses Vision's built-in 1303-identifier taxonomy, which needs no model file.",
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
