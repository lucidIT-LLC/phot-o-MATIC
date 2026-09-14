import Foundation

/// The criteria file — decision #499's mechanism, and the thing a verdict comes
/// from.
///
/// WHY THIS FILE EXISTS AND WHY IT IS DATA RATHER THAN CODE. #499, operator
/// ruling: *"it should have pixel hard earned logic tied into it… we need pixel
/// experience driving it."* A Walk that does not carry her experience "is a
/// light meter", and 0.4.1 shipped the light meter because there was no
/// mechanism to produce a judgment. The mechanism is this: Andy's logic stops
/// being prose containing numbers and becomes DATA Walk executes and her skill
/// explains. One source of truth, two readers.
///
/// It closes a MEASURED defect rather than tidying an idea. Pixel 2.2.0 shipped
/// a reversed `magentaGreen` sign in the very section written to prevent an
/// overcorrection, while a section one screen above carried the correct
/// direction — two halves of one document disagreeing with every verifier
/// passing (task #719, decision #492). Numbers living in prose drift silently;
/// the same numbers as data with a test cannot reverse without a test failing.
///
/// EVERY RULE CARRIES FOUR FIELDS, and #499 names the fourth as the teaching
/// device: the measurement it reads, the threshold, the reason in language, and
/// THE SESSION OR DECISION THAT ESTABLISHED IT. Field four is what lets a
/// verdict cite its own origin, so the operator can audit the advice instead of
/// trusting it. The loader REFUSES a rule missing either the reason or the
/// origin — an unattributable judgment is the failure mode this file exists to
/// prevent.
///
/// WHAT WALK DOES NOT DO HERE. It does not author criteria. No criteria ship
/// with this build; `coach.verdict` is in `Walk.notImplemented` for that reason
/// and says so. Walk validates, versions, loads and applies them, and reports
/// their absence as an absence.
public struct Criteria: Sendable {

    // MARK: - the file

    public struct Header: Sendable {
        /// The criteria set's own version, under the same discipline as
        /// `Walk.version` — #499: "a criteria set that cannot detect its own
        /// staleness has the same defect as a document that cannot."
        public let version: String
        /// The Walk this set was written against. A mismatch stops verdicts.
        public let walk: String
        /// Who owns the judgment in it. Andy, on this product.
        public let owner: String
        /// When it was established, as the author wrote it.
        public let established: String
        public let note: String?
    }

    /// One measurable quantity a rule may read. Named selectors rather than a
    /// free-text expression, because a criteria file that can compute anything
    /// is a second engine living outside the tests.
    public enum Measurement: Sendable, Equatable {
        /// A Vision classifier confidence, e.g. `vision.lightning`. `nil` when
        /// classification was off — which is NOT zero, and a rule reading it
        /// does not fire rather than firing on a false zero.
        case vision(String)
        /// Relative luminance rise over the local median baseline, as a
        /// fraction (0.36 is the +36% on clip 0012 frame 2347).
        case relativeRise
        /// The same rise expressed in percent, because that is how the operator
        /// reads it and a criteria file should not force a unit conversion on
        /// its author.
        case relativeRisePercent
        /// The rise in multiples of the clip's own robust sigma.
        case sigma
        /// 10-bit Y-plane mean. Approximate unless the scan ran at stride 1.
        case yMean
        /// 10-bit Y-plane maximum code value.
        case yMax
        /// How many adjacent frames merged into this candidate.
        case mergedFrames

        public var selector: String {
            switch self {
            case .vision(let id): return "vision.\(id)"
            case .relativeRise: return "relativeRise"
            case .relativeRisePercent: return "relativeRisePercent"
            case .sigma: return "sigma"
            case .yMean: return "yMean"
            case .yMax: return "yMax"
            case .mergedFrames: return "mergedFrames"
            }
        }

        static func parse(_ s: String) -> Measurement? {
            if s.hasPrefix("vision.") {
                let id = String(s.dropFirst("vision.".count))
                return id.isEmpty ? nil : .vision(id)
            }
            switch s {
            case "relativeRise": return .relativeRise
            case "relativeRisePercent": return .relativeRisePercent
            case "sigma": return .sigma
            case "yMean": return .yMean
            case "yMax": return .yMax
            case "mergedFrames": return .mergedFrames
            default: return nil
            }
        }

        public static let allSelectors = [
            "vision.<identifier>", "relativeRise", "relativeRisePercent",
            "sigma", "yMean", "yMax", "mergedFrames",
        ]
    }

    public enum Comparison: String, Sendable {
        case atLeast, atMost, greaterThan, lessThan, between

        public func holds(_ x: Double, _ value: Double, _ upper: Double?) -> Bool {
            switch self {
            case .atLeast: return x >= value
            case .atMost: return x <= value
            case .greaterThan: return x > value
            case .lessThan: return x < value
            case .between: guard let upper else { return false }
                           return x >= value && x <= upper
            }
        }

        public func describe(_ value: Double, _ upper: Double?) -> String {
            switch self {
            case .between: return String(format: "between %.4f and %.4f", value, upper ?? .nan)
            default: return String(format: "%@ %.4f", rawValue, value)
            }
        }
    }

    /// One condition. All of a rule's conditions must hold for it to fire.
    public struct Condition: Sendable {
        public let measurement: Measurement
        public let op: Comparison
        public let value: Double
        public let upper: Double?
    }

    /// One rule: the four #499 fields, the band it assigns, the one change that
    /// band 2 owes, and the next-flight lesson #513 requires of every band.
    public struct Rule: Sendable {
        public let id: String
        public let band: Coaching.Band
        /// Field 1 and 2 — the measurements read and the thresholds applied.
        public let when: [Condition]
        /// Field 3 — the reason, in language a photographer can act on. #513:
        /// it names the craft a buyer is paying for, not the measurement.
        public let reason: String
        /// Field 4 — the session or decision that established it. The loader
        /// refuses a rule without one.
        public let origin: String
        /// Band 2 only, and required there: the ONE specific change.
        public let change: String?
        /// The forward question. Defaults to `Coaching.forwardQuestion`; a rule
        /// may word it differently but may not remove it.
        public let forwardQuestion: String?
        /// #513: every band teaches next flight — hover position, framing,
        /// exposure lock, whether 60 fps for a 30 fps cut was right.
        public let nextFlight: String
    }

    public let header: Header
    public let rules: [Rule]
    /// Where it was loaded from, for a report that has to name its source.
    public let source: String

    public var version: String { header.version }

    // MARK: - staleness

    /// Whether this criteria set was written against the running Walk.
    ///
    /// Same rule as `Walk.check(expecting:)` and for the same reason: an OLDER
    /// Walk than the criteria expect may not have the measurement a rule reads,
    /// and a NEWER Walk may have changed what one means. Either way the
    /// criteria must be re-verified rather than silently applied — so `Coach`
    /// renders NO verdicts on a mismatch and reports the mismatch as the
    /// reason. A coaching verdict from criteria that do not match the engine is
    /// exactly the drift this repository was built to make impossible.
    public var versionCheck: Walk.Check { Walk.check(expecting: header.walk) }

    // MARK: - errors

    public enum Invalid: Error, CustomStringConvertible {
        case unreadable(String)
        case notJSON(String)
        case missingHeader
        case missingField(String, rule: String?)
        case unknownBand(String, rule: String)
        case unknownMeasurement(String, rule: String)
        case unknownComparison(String, rule: String)
        case betweenNeedsUpper(rule: String)
        case noConditions(rule: String)
        case duplicateRuleID(String)
        case noRules
        case changeRequiredForBand2(rule: String)
        case changeOnWrongBand(rule: String, band: String)
        case emptyForwardQuestion(rule: String)

        public var description: String {
            switch self {
            case .unreadable(let p): return "criteria file could not be read: \(p)"
            case .notJSON(let d): return "criteria file is not the expected JSON object: \(d)"
            case .missingHeader: return "criteria file has no `criteria` header — version, walk, owner and established are all required"
            case .missingField(let f, let r):
                return r.map { "rule \($0) is missing `\(f)`" } ?? "criteria file is missing `\(f)`"
            case .unknownBand(let b, let r): return "rule \(r) names band `\(b)`, which is not one of \(Coaching.Band.allCases.map(\.rawValue).joined(separator: ", "))"
            case .unknownMeasurement(let m, let r): return "rule \(r) reads `\(m)`, which Walk does not measure. Available: \(Measurement.allSelectors.joined(separator: ", "))"
            case .unknownComparison(let o, let r): return "rule \(r) uses comparison `\(o)`; use one of \(Comparison.allCases.map(\.rawValue).joined(separator: ", "))"
            case .betweenNeedsUpper(let r): return "rule \(r) uses `between` and must give `upper` as well as `value`"
            case .noConditions(let r): return "rule \(r) has an empty `when` — a rule that reads nothing fires on everything"
            case .duplicateRuleID(let id): return "rule id `\(id)` appears twice; a verdict must be able to cite exactly one rule"
            case .noRules: return "criteria file declares no rules, so it can produce no verdict. An empty set is reported as absence, not loaded as silence."
            case .changeRequiredForBand2(let r):
                return "rule \(r) assigns HAS POTENTIAL, WITH THIS and gives no `change`. Decision #513 requires the ONE specific change; the band is meaningless without it."
            case .changeOnWrongBand(let r, let band):
                return "rule \(r) is band \(band) and carries a `change`. Only HAS POTENTIAL, WITH THIS names a change — on any other band it reads as a hedge."
            case .emptyForwardQuestion(let r):
                return "rule \(r) sets `forwardQuestion` to an empty string. #513 makes the question REQUIRED, not decoration — a rule may word it differently and may not remove it."
            }
        }
    }

    // MARK: - resolution

    /// Environment variable that names a criteria file explicitly.
    public static let environmentKey = "WALK_CRITERIA"

    /// Where Walk looks when nothing is named. Application Support, not the
    /// bundle: the criteria are Andy's to publish and the operator's to
    /// install, and a build that carried its own copy would be back to numbers
    /// frozen into code.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Walk/criteria.json")
    }

    /// Every place Walk looked, in order, so an absence can be reported as one
    /// rather than as a silent lack of verdicts.
    public struct Resolution: Sendable {
        public let url: URL?
        public let source: String
        public let searched: [String]
        /// The default location this resolution actually consulted.
        ///
        /// CARRIED RATHER THAN RE-DERIVED, because with `defaultLocation`
        /// injectable a caller that wanted to name the default in a message
        /// would otherwise read `Criteria.defaultURL` back and print a path that
        /// was never searched. A resolution that misnames where it looked is
        /// the same defect as one that does not say at all.
        public let defaultLocation: URL
        public var found: Bool { url != nil }
    }

    /// Resolve which criteria file to load, in order: the caller's explicit
    /// path, then `WALK_CRITERIA`, then the default location.
    ///
    /// `defaultLocation` IS THE TEST SEAM AND IT WAS ADDED BECAUSE ITS ABSENCE
    /// MADE A TEST PASS BY COINCIDENCE (2026-09-12).
    /// `defaultURL` resolves through `FileManager.urls(for:
    /// .applicationSupportDirectory, in: .userDomainMask)`, which reads the
    /// user record from the password database and NOT the `HOME` environment
    /// variable — measured by overriding HOME and watching both runs still
    /// resolve to the same real path. So there was no way to reach the
    /// "no criteria installed" state from a test without moving the operator's
    /// live file, and `WALK_CRITERIA` is no help: it SELECTS an alternative
    /// file, it cannot assert an ABSENCE.
    ///
    /// The consequence was measured, not theorised.
    /// `withNoCriteriaTheReportSaysSoAndNamesWhereItLooked` asserts the absence
    /// branch. It passed on the author's machine only because the installed
    /// criteria happened to declare the same version as the build; when Walk
    /// went to 0.5.5 the installed 0.5.0 set was correctly rejected as stale,
    /// the STALENESS branch rendered instead, and the test failed. It had never
    /// been testing the absence branch in isolation — it was reading host state
    /// and getting lucky. A test that passes by coincidence is the same defect
    /// class as a document that cannot detect its own staleness, which is the
    /// thing this file exists to prevent.
    ///
    /// Injecting the location is the whole fix: with it, "absent" and
    /// "present but stale" are both reachable on their own terms, on any
    /// machine, without touching what the operator has installed.
    public static func resolve(explicit: URL? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaultLocation: URL? = nil)
        -> Resolution {
        let fallback = defaultLocation ?? defaultURL
        var searched = [String]()
        if let explicit {
            searched.append("named by the caller: \(explicit.path)")
            if FileManager.default.fileExists(atPath: explicit.path) {
                return Resolution(url: explicit, source: "named by the caller", searched: searched, defaultLocation: fallback)
            }
        }
        if let fromEnv = environment[environmentKey], !fromEnv.isEmpty {
            let url = URL(fileURLWithPath: fromEnv)
            searched.append("\(environmentKey)=\(fromEnv)")
            if FileManager.default.fileExists(atPath: url.path) {
                return Resolution(url: url, source: environmentKey, searched: searched, defaultLocation: fallback)
            }
        }
        searched.append("default: \(fallback.path)")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return Resolution(url: fallback, source: "default location", searched: searched,
                              defaultLocation: fallback)
        }
        return Resolution(url: nil, source: "not found", searched: searched,
                          defaultLocation: fallback)
    }

    // MARK: - loading

    public static func load(from url: URL) throws -> Criteria {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Invalid.unreadable(url.path)
        }
        return try parse(data, source: url.path)
    }

    public static func parse(_ data: Data, source: String) throws -> Criteria {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) }
        catch { throw Invalid.notJSON("\(error)") }
        guard let root = any as? [String: Any] else {
            throw Invalid.notJSON("top level is not an object")
        }
        guard let head = root["criteria"] as? [String: Any] else { throw Invalid.missingHeader }

        func required(_ key: String, in o: [String: Any], rule: String? = nil) throws -> String {
            guard let s = o[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Invalid.missingField(key, rule: rule) }
            return s
        }

        let header = Header(version: try required("version", in: head),
                            walk: try required("walk", in: head),
                            owner: try required("owner", in: head),
                            established: try required("established", in: head),
                            note: head["note"] as? String)

        guard let rawRules = root["rules"] as? [[String: Any]], !rawRules.isEmpty else {
            throw Invalid.noRules
        }

        var rules = [Rule]()
        var seen = Set<String>()
        for raw in rawRules {
            let id = try required("id", in: raw)
            guard seen.insert(id).inserted else { throw Invalid.duplicateRuleID(id) }

            let bandName = try required("band", in: raw, rule: id)
            guard let band = Coaching.Band(rawValue: bandName) else {
                throw Invalid.unknownBand(bandName, rule: id)
            }

            guard let rawWhen = raw["when"] as? [[String: Any]], !rawWhen.isEmpty else {
                throw Invalid.noConditions(rule: id)
            }
            var conditions = [Condition]()
            for c in rawWhen {
                let selector = try required("measurement", in: c, rule: id)
                guard let measurement = Measurement.parse(selector) else {
                    throw Invalid.unknownMeasurement(selector, rule: id)
                }
                let opName = try required("op", in: c, rule: id)
                guard let op = Comparison(rawValue: opName) else {
                    throw Invalid.unknownComparison(opName, rule: id)
                }
                guard let value = (c["value"] as? NSNumber)?.doubleValue else {
                    throw Invalid.missingField("value", rule: id)
                }
                let upper = (c["upper"] as? NSNumber)?.doubleValue
                if op == .between, upper == nil { throw Invalid.betweenNeedsUpper(rule: id) }
                conditions.append(Condition(measurement: measurement, op: op,
                                            value: value, upper: upper))
            }

            // Field 3 and field 4. Both required, and field 4 is the one this
            // factory keeps losing: a judgment with no origin cannot be audited.
            let reason = try required("reason", in: raw, rule: id)
            let origin = try required("origin", in: raw, rule: id)
            let nextFlight = try required("nextFlight", in: raw, rule: id)

            let change = (raw["change"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            if band.requiresChange, change == nil { throw Invalid.changeRequiredForBand2(rule: id) }
            if !band.requiresChange, change != nil {
                throw Invalid.changeOnWrongBand(rule: id, band: band.rawValue)
            }

            // An ABSENT forwardQuestion takes Walk's constant. A PRESENT but
            // empty one is an attempt to delete the question, and is refused.
            var question: String? = nil
            if let q = raw["forwardQuestion"] as? String {
                guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Invalid.emptyForwardQuestion(rule: id)
                }
                question = q
            }

            rules.append(Rule(id: id, band: band, when: conditions, reason: reason,
                              origin: origin, change: change,
                              forwardQuestion: question, nextFlight: nextFlight))
        }
        return Criteria(header: header, rules: rules, source: source)
    }

    // MARK: - reading a candidate

    /// The measured value a condition reads, or `nil` when Walk did not measure
    /// it on this candidate. NIL IS NOT ZERO — classification off is not a
    /// confidence of nought, and a rule reading an unmeasured quantity does not
    /// fire rather than firing on a false zero.
    public static func value(of measurement: Measurement,
                             on candidate: ClipScan.Candidate) -> Double? {
        switch measurement {
        case .vision(let id): return candidate.confidence(id)
        case .relativeRise: return candidate.relativeRise
        case .relativeRisePercent: return candidate.relativeRise * 100
        case .sigma: return candidate.sigma
        case .yMean: return candidate.yMean
        case .yMax: return candidate.yMax.map(Double.init)
        case .mergedFrames: return Double(candidate.mergedFrames)
        }
    }
}

extension Criteria.Comparison: CaseIterable {}
