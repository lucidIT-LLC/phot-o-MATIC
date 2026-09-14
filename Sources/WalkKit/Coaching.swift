import Foundation

/// The coaching verdict — decision #513, and the shape of Walk's output.
///
/// THE RULING, in the operator's own words on seeing the Storm Roll 0012 proof
/// sheet: *"it should be more o-MATIC than it currently is — remember the goal
/// is to teach and keep the user moving forward in their art. so you need to
/// say these are good, and why, these could be with this, where did you want to
/// go? and these ones aren't worth the trouble. The goal is sellable output.
/// professional output. make better photographers."*
///
/// WHAT WAS WRONG, AND WHAT WAS NOT. The sheet's own strapline convicted it:
/// "Every frame measured; none judged." That is honest about an INSTRUMENT and
/// it is the wrong promise for the product. A light meter measures; a coach
/// judges, says why, and asks where you were going. Thirteen cards of rise,
/// confidence, Y-mean and Y-max is a readout a photographer cannot act on.
///
/// The measurement layer was NOT the defect and is not discarded. 13 candidates
/// out of 2,771 frames of 4K60 HLG in 29.5 s, with the statistical floor
/// honestly reported as a threshold rather than a verdict, is good and fast.
/// #513 rejected removing it in terms: measurements become the EVIDENCE UNDER a
/// verdict, available and not leading. Removing them would make the coach
/// unfalsifiable, which is the opposite of this factory's method — so every
/// verdict here carries the numbers that produced it and the rule that read
/// them.
///
/// WHERE THE JUDGMENT COMES FROM, and it is not from here. Walk owns the SHAPE;
/// `Criteria` owns the content, and #499 rules that it is Andy's. This type
/// will not invent a band. With no criteria file, `Coach.report` returns
/// `available == false` with the reason and every place it looked — an absence
/// reported as an absence, which is the one thing the 0.4.1 sheet did not do.
public enum Coaching {

    // MARK: - the three bands

    /// #513's three bands. The raw values are the wire names; `label` is the
    /// operator's wording and is what a human sees.
    public enum Band: String, Sendable, CaseIterable {
        /// "these are good, and why." The reason names the craft a buyer is
        /// paying for, not the measurement.
        case sellableAsShot
        /// "these could be with this, where did you want to go?" One specific
        /// change, then the question — which is required.
        case hasPotentialWithThis
        /// "these ones aren't worth the trouble." Why, plainly, so the tell is
        /// learned and not shot again. No softening.
        case notWorthTheTrouble

        public var label: String {
            switch self {
            case .sellableAsShot: return "KEEPER"
            case .hasPotentialWithThis: return "HAS POTENTIAL, WITH THIS"
            case .notWorthTheTrouble: return "NOT WORTH THE TROUBLE"
            }
        }

        /// What the band promises the photographer, as the ruling words it.
        public var promise: String {
            switch self {
            case .sellableAsShot:
                return "Good, and why — the reason names the craft a buyer is paying for, not the number."
            case .hasPotentialWithThis:
                return "One specific change that would make it sell, then where you were going."
            case .notWorthTheTrouble:
                return "Why, plainly, so the tell is learned and not shot again."
            }
        }

        /// Only band 2 names a change. On any other band a change reads as a
        /// hedge, and `Criteria` refuses one there.
        public var requiresChange: Bool { self == .hasPotentialWithThis }

        /// Only band 2 asks the forward question. #513 makes it REQUIRED there
        /// — it is the mechanism that keeps a photographer moving forward
        /// instead of having their work sorted for them.
        public var requiresForwardQuestion: Bool { self == .hasPotentialWithThis }

        /// Best first, for a report a photographer reads top down.
        public var order: Int {
            switch self {
            case .sellableAsShot: return 0
            case .hasPotentialWithThis: return 1
            case .notWorthTheTrouble: return 2
            }
        }
    }

    // MARK: - criteria shipped inside the build

    /// A criteria set compiled INTO Walk, if one ever ships. Nil today, and the
    /// nil is load-bearing in two directions.
    ///
    /// `coach.verdict` sits in `Walk.notImplemented` saying "no criteria ship
    /// with this build". That sentence is prose about a mechanism, which is the
    /// exact thing this repository exists to stop going stale — so the two are
    /// TIED BY A TEST: this constant being non-nil while `coach.verdict` is
    /// still declared absent fails the suite, and so does the reverse. Whoever
    /// ships Andy's criteria cannot ship them quietly.
    ///
    /// An installed file still wins over this, so an operator can override a
    /// shipped set without rebuilding.
    public static let shippedCriteriaJSON: String? = nil

    /// The forward question, verbatim from #513. A rule may word it differently
    /// for its own subject; it may not remove it.
    public static let forwardQuestion = "Where did you want to go?"

    // MARK: - a verdict

    /// One measurement that a rule read, with the threshold it was tested
    /// against. THIS IS THE FALSIFIABILITY. A verdict whose evidence cannot be
    /// inspected is an opinion with a frame number attached.
    public struct Evidence: Sendable {
        public let measurement: String
        public let measured: Double
        public let required: String
        public let held: Bool
    }

    /// A verdict on one candidate frame.
    ///
    /// The initializer THROWS, and that is the enforcement rather than a
    /// comment asking nicely. #513's band 2 is the whole mechanism of the
    /// ruling and it is two parts — the one change and the question. A band 2
    /// verdict that lost either one would still render, still look like
    /// coaching, and quietly be a sorting label. It cannot be constructed.
    public struct Verdict: Sendable {
        public let band: Band
        public let frame: Int
        public let timecode: String
        public let seconds: Double
        public let reason: String
        /// Band 2 only: the ONE specific change.
        public let change: String?
        /// Band 2 only, and never nil there.
        public let forwardQuestion: String?
        /// #513: every band teaches next flight.
        public let nextFlight: String
        /// The rule that fired and, through it, the decision that established
        /// the judgment — #499's fourth field.
        public let ruleID: String
        public let origin: String
        public let evidence: [Evidence]
        public let thumbnail: URL?

        public enum Malformed: Error, CustomStringConvertible {
            case emptyReason(frame: Int)
            case emptyNextFlight(frame: Int)
            case missingChange(frame: Int)
            case changeOnWrongBand(frame: Int, band: String)
            case missingForwardQuestion(frame: Int)
            case forwardQuestionOnWrongBand(frame: Int, band: String)
            case noEvidence(frame: Int)

            public var description: String {
                switch self {
                case .emptyReason(let f): return "frame \(f): a verdict with no reason is a sorting label — #513 requires the why on every band"
                case .emptyNextFlight(let f): return "frame \(f): no next-flight lesson. #513: a verdict the photographer cannot act on next time is a sorting label wearing a coach's voice."
                case .missingChange(let f): return "frame \(f): HAS POTENTIAL, WITH THIS with no change. The band IS the change."
                case .changeOnWrongBand(let f, let b): return "frame \(f): band \(b) carries a change; only HAS POTENTIAL, WITH THIS does."
                case .missingForwardQuestion(let f): return "frame \(f): HAS POTENTIAL, WITH THIS with no forward question. #513 makes it required, not decoration."
                case .forwardQuestionOnWrongBand(let f, let b): return "frame \(f): band \(b) asks the forward question; only HAS POTENTIAL, WITH THIS does."
                case .noEvidence(let f): return "frame \(f): a verdict with no evidence under it cannot be audited, and #513 kept the measurements precisely so that it can be"
                }
            }
        }

        public init(band: Band, frame: Int, timecode: String, seconds: Double,
                    reason: String, change: String?, forwardQuestion: String?,
                    nextFlight: String, ruleID: String, origin: String,
                    evidence: [Evidence], thumbnail: URL?) throws {
            func blank(_ s: String?) -> Bool {
                (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if blank(reason) { throw Malformed.emptyReason(frame: frame) }
            if blank(nextFlight) { throw Malformed.emptyNextFlight(frame: frame) }
            if band.requiresChange {
                if blank(change) { throw Malformed.missingChange(frame: frame) }
            } else if !blank(change) {
                throw Malformed.changeOnWrongBand(frame: frame, band: band.rawValue)
            }
            if band.requiresForwardQuestion {
                if blank(forwardQuestion) { throw Malformed.missingForwardQuestion(frame: frame) }
            } else if !blank(forwardQuestion) {
                throw Malformed.forwardQuestionOnWrongBand(frame: frame, band: band.rawValue)
            }
            if evidence.isEmpty { throw Malformed.noEvidence(frame: frame) }

            self.band = band; self.frame = frame; self.timecode = timecode
            self.seconds = seconds; self.reason = reason
            self.change = band.requiresChange ? change : nil
            self.forwardQuestion = band.requiresForwardQuestion ? forwardQuestion : nil
            self.nextFlight = nextFlight; self.ruleID = ruleID; self.origin = origin
            self.evidence = evidence; self.thumbnail = thumbnail
        }
    }

    // MARK: - a lesson the engine itself established

    /// A teaching point that comes out of Walk's own MEASUREMENTS rather than
    /// out of anyone's taste, so it is Walk's to state and does not wait on the
    /// criteria file.
    public struct Lesson: Sendable {
        public let id: String
        public let headline: String
        public let detail: String
        public let origin: String
    }

    /// #513's teaching spine, measured on clip 0012 and corrected twice in
    /// public: #504 superseded #495's six-strike count on exactly this, and
    /// #740 found this lesson comparing two DIFFERENT COLOUR SPACES to make its
    /// point — 2347's linear rise against 2388's Y-plane rise, no space named
    /// on either — which is the same defect #740 fixed in every other output
    /// surface.
    ///
    /// EVERY NUMBER HERE IS READ OFF THE ENGINE, and
    /// `KnownAnswerTests.theLuminanceLessonQuotesTheEnginesOwnNumbers` re-derives
    /// all five from a scan of the clip and fails if the prose and the engine
    /// diverge. That is why the figures sit at this precision instead of being
    /// rounded into safety: a rounded number cannot be checked against an
    /// instrument. #740 is explicit that these come from the engine and not
    /// from a decision record, and the check is what makes that true rather
    /// than merely intended.
    ///
    /// Frame 2347 lifts the picture +36.03% in pinned linear BT.2020 and scores
    /// 0.3435 for lightning. Frame 2388 lifts it +3.69% in that same space —
    /// +0.87% on the gamma-encoded 10-bit Y plane, which does not even clear the
    /// detector's own 1% floor — and scores 0.6616: nearly double the confidence
    /// at a tenth of the brightness. Sorting by brightness picks the wrong
    /// frame, and the first scan of this clip missed two real cloud-to-ground
    /// strikes that way.
    public static let luminanceIsNotLightning = Lesson(
        id: "luminanceIsNotLightning",
        headline: "Luminance finds bright flashes. Classification finds lightning. They are different measurements.",
        detail: """
            On clip 0012, 2388 lifted the frame +3.69% in pinned linear BT.2020 \
            (+0.87% on the gamma-encoded Y plane) and scores 0.6616, against \
            2347's +36.03% linear and 0.3435 — nearly double the confidence at a \
            tenth of the brightness, because the bolt is thin, distant and well \
            formed. It has the SHAPE of lightning without the BRIGHTNESS of it. \
            The two percentages in that first pair are different quantities and no \
            fixed factor converts between them; on 2347 the same event reads \
            +36.03% linear against +6.02% on the Y plane. On the Y plane 2388 is \
            not a candidate at all — +0.87% is under the detector's 1% floor, and \
            a threshold rejecting it is how the first scan of this clip lost two \
            real cloud-to-ground strikes. Rank by brightness and you will hand \
            back the wrong frame; that is a lesson, not a statistic.
            """,
        origin: "decision #504, correcting #495; restated as the teaching spine by #513; numbers re-measured off the engine and space-labelled under #740")

    public static let lessons: [Lesson] = [luminanceIsNotLightning]

    // MARK: - the report

    public struct Report: Sendable {
        /// False means NO VERDICT WAS RENDERED and `unavailableReason` says why.
        /// It is never false silently and it is never true with an empty band
        /// set standing in for one.
        public let available: Bool
        public let unavailableReason: String?
        /// Every place Walk looked for criteria, when it did not find them.
        public let searched: [String]
        public let criteriaVersion: String?
        public let criteriaOwner: String?
        public let criteriaSource: String?
        public let verdicts: [Verdict]
        /// Candidates no rule covered. THEY DO NOT FALL INTO A BAND. A default
        /// band would make a thin criteria set look like a complete judgment,
        /// which is the same defect as an absent capability reading as a
        /// working one.
        public let uncovered: [Int]
        /// Rules that fired but could not be turned into a verdict, with why.
        /// Recorded rather than dropped, because a dropped candidate is
        /// indistinguishable from one that was never judged.
        public let malformed: [String]
        public let lessons: [Lesson]

        public var candidatesJudged: Int { verdicts.count }

        public func verdicts(in band: Band) -> [Verdict] { verdicts.filter { $0.band == band } }

        public var counts: [Band: Int] {
            var c = [Band: Int]()
            for b in Band.allCases { c[b] = 0 }
            for v in verdicts { c[v.band, default: 0] += 1 }
            return c
        }

        /// One line a host or a sheet can print. States the absence when there
        /// is one, in the same breath as the counts, so neither can be read
        /// without the other.
        public var headline: String {
            guard available else {
                return "No coaching verdict rendered — \(unavailableReason ?? "reason not recorded")"
            }
            let c = counts
            let parts = Band.allCases.sorted { $0.order < $1.order }
                .map { "\(c[$0] ?? 0) \($0.label)" }
            var s = parts.joined(separator: " · ")
            if !uncovered.isEmpty {
                s += " · \(uncovered.count) candidate\(uncovered.count == 1 ? "" : "s") no rule covered, left unjudged rather than banded"
            }
            return s
        }

        static func unavailable(_ reason: String, searched: [String] = []) -> Report {
            Report(available: false, unavailableReason: reason, searched: searched,
                   criteriaVersion: nil, criteriaOwner: nil, criteriaSource: nil,
                   verdicts: [], uncovered: [], malformed: [], lessons: Coaching.lessons)
        }
    }

    // MARK: - the coach

    /// Applies a criteria set to a scan. Deterministic, and it renders nothing
    /// the criteria did not say — #494's seam between the engine and the
    /// judgment layer runs straight through this type.
    public struct Coach: Sendable {
        public let criteria: Criteria?
        public let loadError: String?
        public let resolution: Criteria.Resolution?

        /// A coach with criteria already in hand.
        public init(criteria: Criteria) {
            self.criteria = criteria; self.loadError = nil; self.resolution = nil
        }

        /// Resolve and load. A criteria file that is PRESENT AND BROKEN is a
        /// different answer from one that is absent, and both are reported —
        /// swallowing a parse error into "no criteria" would hide the one case
        /// where somebody tried.
        /// `defaultLocation` is the test seam — see `Criteria.resolve` for the
        /// measurement that forced it. Production callers omit it and get the
        /// installed location; a test passes a directory it controls, so
        /// "no criteria installed" and "installed but stale" are both reachable
        /// without depending on what is on the machine running the test.
        public init(explicit: URL? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    defaultLocation: URL? = nil) {
            let r = Criteria.resolve(explicit: explicit, environment: environment,
                                     defaultLocation: defaultLocation)
            self.resolution = r
            guard let url = r.url else {
                // Nothing installed. Fall back to a set compiled into the build
                // if one ever ships — see `shippedCriteriaJSON`.
                if let json = Coaching.shippedCriteriaJSON {
                    do {
                        self.criteria = try Criteria.parse(Data(json.utf8),
                                                          source: "shipped with Walk \(Walk.version)")
                        self.loadError = nil
                    } catch {
                        self.criteria = nil
                        self.loadError = "the criteria compiled into Walk \(Walk.version) do not load: \(error)"
                    }
                    return
                }
                self.criteria = nil
                self.loadError = nil
                return
            }
            do {
                self.criteria = try Criteria.load(from: url)
                self.loadError = nil
            } catch {
                self.criteria = nil
                self.loadError = "\(url.path): \(error)"
            }
        }

        /// Why no verdict, when there is none. Never a bare false.
        public var unavailableReason: String? {
            if let loadError {
                return "the criteria file is present and unusable — \(loadError)"
            }
            if criteria == nil {
                return """
                    no criteria file. Decision #499 rules that Andy's hard-earned logic \
                    drives Walk's verdicts, and #513 that the output is a coaching verdict \
                    rather than a readout; the criteria file is the mechanism a verdict \
                    comes from and Walk does not ship one. The measurements are \
                    complete and unjudged. Install a criteria set at \
                    \(resolution?.defaultLocation.path ?? Criteria.defaultURL.path), or name \
                    one with \(Criteria.environmentKey), \
                    and every scan renders bands from it.
                    """
            }
            if let c = criteria, !c.versionCheck.ok {
                return """
                    the criteria file at \(c.source) was written against Walk \
                    \(c.versionCheck.expected) and this build is \(c.versionCheck.actual) — \
                    \(c.versionCheck.detail). No verdict is rendered from criteria that do \
                    not match the engine they read; re-verify the set and bump its `walk` \
                    field deliberately.
                    """
            }
            return nil
        }

        public var isReady: Bool { unavailableReason == nil }

        /// Judge one clip's candidates.
        public func report(for scan: ClipScan.Result) -> Report {
            report(for: scan.candidates)
        }

        /// The same judgment against a bare candidate list — what the app has
        /// after a scan, and what a test can construct without a video file.
        public func report(for candidates: [ClipScan.Candidate]) -> Report {
            if let reason = unavailableReason {
                return Report.unavailable(reason, searched: resolution?.searched ?? [])
            }
            guard let criteria else {
                return Report.unavailable("no criteria loaded", searched: resolution?.searched ?? [])
            }

            var verdicts = [Verdict]()
            var uncovered = [Int]()
            var malformed = [String]()

            for candidate in candidates {
                guard let (rule, evidence) = firstMatch(in: criteria, for: candidate) else {
                    uncovered.append(candidate.frame)
                    continue
                }
                do {
                    verdicts.append(try Verdict(
                        band: rule.band,
                        frame: candidate.frame,
                        timecode: candidate.timecode,
                        seconds: candidate.time,
                        reason: rule.reason,
                        change: rule.change,
                        // THE QUESTION IS SUPPLIED HERE WHEN THE RULE DOES NOT
                        // WORD ITS OWN. #513 makes it required, so the default
                        // is the ruling's own sentence and not an empty field.
                        forwardQuestion: rule.band.requiresForwardQuestion
                            ? (rule.forwardQuestion ?? Coaching.forwardQuestion) : nil,
                        nextFlight: rule.nextFlight,
                        ruleID: rule.id,
                        origin: rule.origin,
                        evidence: evidence,
                        thumbnail: candidate.thumbnail))
                } catch {
                    malformed.append("frame \(candidate.frame) matched rule \(rule.id): \(error)")
                }
            }

            verdicts.sort {
                $0.band.order != $1.band.order ? $0.band.order < $1.band.order
                                               : $0.frame < $1.frame
            }
            return Report(available: true, unavailableReason: nil,
                          searched: resolution?.searched ?? [],
                          criteriaVersion: criteria.version,
                          criteriaOwner: criteria.header.owner,
                          criteriaSource: criteria.source,
                          verdicts: verdicts, uncovered: uncovered,
                          malformed: malformed, lessons: Coaching.lessons)
        }

        /// First rule whose every condition holds. ORDER IN THE FILE IS
        /// PRECEDENCE, and it is the author's to set — a scoring blend would put
        /// Walk back in the business of weighing judgments it did not make.
        func firstMatch(in criteria: Criteria, for candidate: ClipScan.Candidate)
            -> (Criteria.Rule, [Evidence])? {
            for rule in criteria.rules {
                var evidence = [Evidence]()
                var allHeld = true
                for condition in rule.when {
                    guard let measured = Criteria.value(of: condition.measurement, on: candidate) else {
                        // UNMEASURED, NOT ZERO. The rule does not fire.
                        allHeld = false
                        break
                    }
                    let held = condition.op.holds(measured, condition.value, condition.upper)
                    evidence.append(Evidence(measurement: condition.measurement.selector,
                                             measured: measured,
                                             required: condition.op.describe(condition.value, condition.upper),
                                             held: held))
                    if !held { allHeld = false; break }
                }
                if allHeld, !evidence.isEmpty { return (rule, evidence) }
            }
            return nil
        }
    }
}
