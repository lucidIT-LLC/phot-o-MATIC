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
/// A consumer — Pixel's skill, an MCP wrapper, an app — is written against a
/// specific Walk. `Contract.check(expecting:)` lets it FAIL LOUDLY rather than
/// proceed on stale instructions.
public enum Walk {
    public static let version = "0.2.0"

    /// Capabilities a consumer may rely on, each with the version that
    /// introduced it. A consumer naming a capability absent from this list is
    /// describing something Walk does not do.
    public static let capabilities: [String: String] = [
        "hlg.sdr.transform":  "0.1.0",  // BT.2100 inverse OETF + OOTF + BT.2020→709
        "hlg.systemGamma":    "0.1.0",  // BT.2390 derivation from target nits
        "grade.filmic":       "0.1.0",  // Hable tone map
        "measure.mean":       "0.1.0",  // whole-image channel means, managed
        "measure.meanRaw":    "0.1.0",  // unmanaged file values, CPU reduction
        "measure.castCheck":  "0.1.0",  // channel-spread delta across a grade
        "contract.version":   "0.2.0",  // this surface
    ]

    /// What Walk explicitly does NOT do yet. Stated so a consumer cannot infer
    /// capability from silence — absence indistinguishable from success is the
    /// failure mode this factory measures most often.
    public static let notImplemented: [String] = [
        "video.read", "video.write", "video.retime", "video.scan",
        "classify.vision", "ingest.dump", "page.bestWorst",
        "touchup", "trim", "app.drive",
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
