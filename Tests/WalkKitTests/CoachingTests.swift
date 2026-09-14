import Testing
import Foundation
@testable import WalkKit

// THE BANDS MUST BE ABLE TO FAIL, the same way the version contract must.
//
// Decision #513 is a ruling about SHAPE: three bands, a reason on every one, the
// ONE change on band 2 followed by the forward question, and a next-flight
// lesson throughout. A shape enforced by prose is the defect this repository was
// built around — Pixel 2.2.0 shipped a reversed sign past every verifier because
// the rule lived in a sentence. So these tests assert the REFUSALS: a band 2
// verdict with no change, a band 2 verdict with no question, a rule with no
// origin, criteria that do not match the engine. If any of them start passing,
// the coach has quietly become a sorting label again.

// MARK: - fixtures

private func candidate(_ frame: Int,
                       rise: Double = 0.10,
                       lightning: Double? = 0.50,
                       yMean: Double? = 420,
                       merged: Int = 1) -> ClipScan.Candidate {
    ClipScan.Candidate(
        frame: frame,
        timecode: String(format: "00:00:%02d:00", frame % 60),
        time: Double(frame) / 60.0,
        ciLuma: 0.5, baseline: 0.4, delta: 0.1,
        relativeRise: rise, sigma: 100, mergedFrames: merged,
        yMean: yMean, yMax: 1007, yClipped: false,
        // nil confidences means CLASSIFICATION WAS OFF, which is not zero.
        confidences: lightning.map { ["lightning": $0] },
        topLabels: [], classifyMilliseconds: lightning == nil ? nil : 13.8,
        thumbnail: nil)
}

/// A minimal well-formed criteria set. Deliberately NOT photographic judgment —
/// the reasons are fixture text, and the real ones are Pixel's under #499.
private func criteriaJSON(walk: String = Walk.version,
                          rules: String) -> String {
    """
    {
      "criteria": {
        "version": "0.0.1-test",
        "walk": "\(walk)",
        "owner": "test fixture",
        "established": "2026-09-12"
      },
      "rules": [\(rules)]
    }
    """
}

private let sellableRule = """
    {
      "id": "fixture-sellable",
      "band": "sellableAsShot",
      "when": [{ "measurement": "vision.lightning", "op": "atLeast", "value": 0.5 }],
      "reason": "fixture reason standing in for Pixel's craft language",
      "origin": "fixture, CoachingTests.swift",
      "nextFlight": "fixture next-flight lesson"
    }
    """

private let potentialRule = """
    {
      "id": "fixture-potential",
      "band": "hasPotentialWithThis",
      "when": [{ "measurement": "vision.lightning", "op": "between", "value": 0.1, "upper": 0.4999 }],
      "reason": "fixture reason",
      "origin": "fixture, CoachingTests.swift",
      "change": "the one fixture change",
      "nextFlight": "fixture next-flight lesson"
    }
    """

private func load(_ json: String) throws -> Criteria {
    try Criteria.parse(Data(json.utf8), source: "test fixture")
}

// MARK: - the bands themselves

@Test func thereAreExactlyThreeBandsAndTheyCarryTheOperatorsWords() {
    #expect(Coaching.Band.allCases.count == 3)
    #expect(Coaching.Band.sellableAsShot.label == "KEEPER")
    #expect(Coaching.Band.hasPotentialWithThis.label == "HAS POTENTIAL, WITH THIS")
    #expect(Coaching.Band.notWorthTheTrouble.label == "NOT WORTH THE TROUBLE")
}

@Test func onlyBandTwoOwesAChangeAndAQuestion() {
    #expect(Coaching.Band.hasPotentialWithThis.requiresChange)
    #expect(Coaching.Band.hasPotentialWithThis.requiresForwardQuestion)
    for band in Coaching.Band.allCases where band != .hasPotentialWithThis {
        #expect(!band.requiresChange)
        #expect(!band.requiresForwardQuestion)
    }
}

@Test func theForwardQuestionIsTheRulingsOwnSentence() {
    #expect(Coaching.forwardQuestion == "Where did you want to go?")
}

// MARK: - the verdict invariants, asserted as refusals

private let someEvidence = [Coaching.Evidence(measurement: "vision.lightning",
                                              measured: 0.66, required: "atLeast 0.5000",
                                              held: true)]

private func verdict(band: Coaching.Band, reason: String = "why it is what it is",
                     change: String? = nil, question: String? = nil,
                     nextFlight: String = "next flight: hold the hover 10 m further out",
                     evidence: [Coaching.Evidence] = someEvidence) throws -> Coaching.Verdict {
    try Coaching.Verdict(band: band, frame: 2388, timecode: "00:00:39:48", seconds: 39.84,
                         reason: reason, change: change, forwardQuestion: question,
                         nextFlight: nextFlight, ruleID: "r", origin: "fixture",
                         evidence: evidence, thumbnail: nil)
}

@Test func bandTwoWithoutTheOneChangeCannotBeConstructed() {
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .hasPotentialWithThis, change: nil,
                        question: Coaching.forwardQuestion)
    }
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .hasPotentialWithThis, change: "   ",
                        question: Coaching.forwardQuestion)
    }
}

@Test func bandTwoWithoutTheForwardQuestionCannotBeConstructed() {
    // THE POINT OF #513. Without this refusal a band 2 verdict still renders,
    // still reads like coaching, and has quietly become a sorting label.
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .hasPotentialWithThis, change: "crop tighter", question: nil)
    }
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .hasPotentialWithThis, change: "crop tighter", question: "")
    }
}

@Test func bandTwoWithBothPartsIsAccepted() throws {
    let v = try verdict(band: .hasPotentialWithThis, change: "crop tighter",
                        question: Coaching.forwardQuestion)
    #expect(v.change == "crop tighter")
    #expect(v.forwardQuestion == Coaching.forwardQuestion)
}

@Test func aChangeOrAQuestionOnTheWrongBandIsRefused() {
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .sellableAsShot, change: "crop tighter")
    }
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .notWorthTheTrouble, question: Coaching.forwardQuestion)
    }
}

@Test func everyBandOwesAReasonAndANextFlightLesson() {
    for band in Coaching.Band.allCases {
        let change = band.requiresChange ? "a change" : nil
        let q = band.requiresForwardQuestion ? Coaching.forwardQuestion : nil
        #expect(throws: Coaching.Verdict.Malformed.self) {
            _ = try verdict(band: band, reason: "", change: change, question: q)
        }
        #expect(throws: Coaching.Verdict.Malformed.self) {
            _ = try verdict(band: band, change: change, question: q, nextFlight: "")
        }
    }
}

@Test func averdictWithNoEvidenceUnderItIsRefused() {
    // #513 kept the measurements so the coach stays falsifiable. A verdict with
    // nothing under it is the unfalsifiable version the ruling rejected.
    #expect(throws: Coaching.Verdict.Malformed.self) {
        _ = try verdict(band: .sellableAsShot, evidence: [])
    }
}

// MARK: - the criteria file, and what it refuses to load

@Test func avalidCriteriaSetLoadsWithItsFourFields() throws {
    let c = try load(criteriaJSON(rules: sellableRule))
    #expect(c.rules.count == 1)
    let r = c.rules[0]
    #expect(r.when[0].measurement == .vision("lightning"))   // field 1
    #expect(r.when[0].value == 0.5)                          // field 2
    #expect(!r.reason.isEmpty)                               // field 3
    #expect(!r.origin.isEmpty)                               // field 4 — the teaching device
    #expect(c.header.owner == "test fixture")
}

@Test func aruleWithNoOriginIsRefused() {
    // #499's fourth field. A judgment that cannot cite where it came from
    // cannot be audited, which is the whole reason the field exists.
    let noOrigin = """
        { "id": "x", "band": "sellableAsShot",
          "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.1 }],
          "reason": "because", "nextFlight": "next time" }
        """
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: noOrigin)) }
}

@Test func aruleWithNoReasonOrNoNextFlightIsRefused() {
    let noReason = """
        { "id": "x", "band": "sellableAsShot",
          "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.1 }],
          "origin": "fixture", "nextFlight": "next time" }
        """
    let noLesson = """
        { "id": "x", "band": "sellableAsShot",
          "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.1 }],
          "origin": "fixture", "reason": "because" }
        """
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: noReason)) }
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: noLesson)) }
}

@Test func bandTwoCriteriaWithoutAChangeAreRefusedAtLoad() {
    let bad = """
        { "id": "x", "band": "hasPotentialWithThis",
          "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.1 }],
          "reason": "because", "origin": "fixture", "nextFlight": "next time" }
        """
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: bad)) }
}

@Test func anEmptyForwardQuestionIsRefusedButAnAbsentOneTakesTheConstant() throws {
    let deleted = """
        { "id": "x", "band": "hasPotentialWithThis",
          "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.01 }],
          "reason": "because", "origin": "fixture", "change": "this one thing",
          "forwardQuestion": "", "nextFlight": "next time" }
        """
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: deleted)) }

    // Absent is fine — Walk supplies #513's own sentence.
    let c = try load(criteriaJSON(rules: potentialRule))
    #expect(c.rules[0].forwardQuestion == nil)
    let report = Coaching.Coach(criteria: c).report(for: [candidate(1, lightning: 0.3)])
    #expect(report.verdicts.first?.forwardQuestion == Coaching.forwardQuestion)
}

@Test func amalformedCriteriaSetIsRefusedRatherThanPartlyRead() {
    let cases = [
        // unknown band
        """
        { "id": "x", "band": "keepIt", "when": [{ "measurement": "relativeRise", "op": "atLeast", "value": 0.1 }],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """,
        // a measurement Walk does not take
        """
        { "id": "x", "band": "sellableAsShot", "when": [{ "measurement": "sharpness", "op": "atLeast", "value": 0.1 }],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """,
        // a comparison that does not exist
        """
        { "id": "x", "band": "sellableAsShot", "when": [{ "measurement": "relativeRise", "op": "vibes", "value": 0.1 }],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """,
        // between with no upper bound
        """
        { "id": "x", "band": "sellableAsShot", "when": [{ "measurement": "relativeRise", "op": "between", "value": 0.1 }],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """,
        // a rule that reads nothing, and would therefore fire on everything
        """
        { "id": "x", "band": "sellableAsShot", "when": [],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """,
    ]
    for rule in cases {
        #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: rule)) }
    }
}

@Test func duplicateRuleIDsAndAnEmptyRuleListAreRefused() {
    #expect(throws: Criteria.Invalid.self) {
        _ = try load(criteriaJSON(rules: "\(sellableRule),\(sellableRule)"))
    }
    #expect(throws: Criteria.Invalid.self) { _ = try load(criteriaJSON(rules: "")) }
    #expect(throws: Criteria.Invalid.self) {
        _ = try Criteria.parse(Data("not json at all".utf8), source: "t")
    }
    #expect(throws: Criteria.Invalid.self) {
        _ = try Criteria.parse(Data("{\"rules\":[]}".utf8), source: "t")
    }
}

// MARK: - the coach applying them

@Test func candidatesAreBandedAndCarryTheEvidenceThatFiredTheRule() throws {
    let c = try load(criteriaJSON(rules: "\(sellableRule),\(potentialRule)"))
    let report = Coaching.Coach(criteria: c).report(for: [
        candidate(2388, lightning: 0.6616),
        candidate(2347, lightning: 0.3435),
    ])
    #expect(report.available)
    #expect(report.counts[.sellableAsShot] == 1)
    #expect(report.counts[.hasPotentialWithThis] == 1)

    let best = try #require(report.verdicts(in: .sellableAsShot).first)
    #expect(best.frame == 2388)
    #expect(best.ruleID == "fixture-sellable")
    #expect(best.origin == "fixture, CoachingTests.swift")
    // The measurement is UNDER the verdict, with the threshold it was tested
    // against — available and not leading.
    let e = try #require(best.evidence.first)
    #expect(e.measurement == "vision.lightning")
    #expect(abs(e.measured - 0.6616) < 1e-9)
    #expect(e.required.contains("atLeast"))
    #expect(e.held)
}

@Test func aCandidateNoRuleCoversIsLeftUnjudgedRatherThanBanded() throws {
    let c = try load(criteriaJSON(rules: sellableRule))
    let report = Coaching.Coach(criteria: c).report(for: [candidate(1, lightning: 0.004)])
    #expect(report.available)
    #expect(report.verdicts.isEmpty)
    #expect(report.uncovered == [1])
    // And the headline says so, so a thin criteria set cannot read as a
    // complete judgment.
    #expect(report.headline.contains("no rule covered"))
}

@Test func anUnmeasuredConfidenceDoesNotFireARuleOnAFalseZero() throws {
    // Classification off is not a confidence of nought. A rule reading
    // vision.lightning must not fire at all, in either direction.
    let atMost = """
        { "id": "cheap", "band": "notWorthTheTrouble",
          "when": [{ "measurement": "vision.lightning", "op": "atMost", "value": 0.01 }],
          "reason": "r", "origin": "o", "nextFlight": "n" }
        """
    let c = try load(criteriaJSON(rules: atMost))
    let report = Coaching.Coach(criteria: c).report(for: [candidate(7, lightning: nil)])
    #expect(report.verdicts.isEmpty)
    #expect(report.uncovered == [7])
}

@Test func criteriaWrittenAgainstAnotherWalkRenderNoVerdict() throws {
    let c = try load(criteriaJSON(walk: "0.1.0", rules: sellableRule))
    #expect(!c.versionCheck.ok)
    let coach = Coaching.Coach(criteria: c)
    #expect(!coach.isReady)
    let report = coach.report(for: [candidate(2388, lightning: 0.9)])
    #expect(!report.available)
    #expect(report.verdicts.isEmpty)
    let reason = try #require(report.unavailableReason)
    #expect(reason.contains("0.1.0"))
    #expect(reason.contains(Walk.version))
}

// MARK: - absence, reported as absence

@Test func withNoCriteriaTheReportSaysSoAndNamesWhereItLooked() {
    // An empty environment and paths that cannot exist: the honest-absence path.
    //
    // `defaultLocation` IS LOAD-BEARING HERE AND WAS ADDED 2026-09-12 AFTER THIS
    // TEST FAILED. Without it the coach fell through to whatever is installed on
    // the machine. This passed for weeks because the installed criteria happened
    // to declare the same version as the build — so the coach was unavailable
    // for a reason that merely LOOKED like the one asserted below. At Walk 0.5.5
    // the installed 0.5.0 set was correctly rejected as STALE, that branch
    // rendered instead, and the three assertions on the absence text failed.
    // The assertion text was never the defect; reading host state was. See
    // `Criteria.resolve` and CriteriaSeamTests.
    let coach = Coaching.Coach(explicit: URL(fileURLWithPath: "/nonexistent/walk-criteria.json"),
                               environment: [:],
                               defaultLocation: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("walk-absent-\(UUID().uuidString).json"))
    #expect(!coach.isReady)
    let report = coach.report(for: [candidate(2388, lightning: 0.9)])
    #expect(!report.available)
    #expect(report.verdicts.isEmpty)
    let reason = report.unavailableReason ?? ""
    #expect(reason.contains("#499"))
    #expect(reason.contains("#513"))
    #expect(reason.contains(Criteria.environmentKey))
    #expect(report.searched.contains { $0.contains("/nonexistent/walk-criteria.json") })
    #expect(report.headline.contains("No coaching verdict rendered"))
}

@Test func acriteriaFilePresentAndBrokenIsADifferentAnswerFromAbsent() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-criteria-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("criteria.json")
    try Data("{ \"criteria\": { \"version\": \"1\" } }".utf8).write(to: file)

    let coach = Coaching.Coach(explicit: file, environment: [:])
    let report = coach.report(for: [candidate(1)])
    #expect(!report.available)
    let reason = try #require(report.unavailableReason)
    #expect(reason.contains("present and unusable"),
            "a broken criteria file must not be swallowed into 'no criteria' — somebody tried")
}

@Test func anInstalledFileIsFoundThroughTheEnvironment() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-criteria-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("criteria.json")
    try Data(criteriaJSON(rules: sellableRule).utf8).write(to: file)

    let coach = Coaching.Coach(environment: [Criteria.environmentKey: file.path])
    #expect(coach.isReady)
    let report = coach.report(for: [candidate(2388, lightning: 0.7)])
    #expect(report.available)
    #expect(report.criteriaSource == file.path)
    #expect(report.criteriaVersion == "0.0.1-test")
}

// MARK: - the teaching spine

@Test func theLuminanceLessonCarriesTheMeasuredNumbersAndItsOrigin() {
    let l = Coaching.luminanceIsNotLightning
    #expect(l.headline.contains("Luminance finds bright flashes"))
    #expect(l.headline.contains("Classification finds lightning"))
    // The measured set from #504/#513, re-measured off the engine under #740.
    // If these drift the lesson is teaching something the engine never measured.
    //
    // THIS TEST CANNOT PROVE THEY CAME FROM THE ENGINE — it compares the prose
    // to constants written beside it, which is the defect class #740 is about,
    // one level up. `KnownAnswerTests.theLuminanceLessonQuotesTheEnginesOwnNumbers`
    // re-derives all five from a scan of clip 0012 and is the real check; it is
    // conditional on the operator's archive, so this unconditional one stays as
    // the CI-visible floor and no more than that.
    #expect(l.detail.contains("+36.03%"))
    #expect(l.detail.contains("0.3435"))
    #expect(l.detail.contains("+3.69%"))
    // The Y-plane figure, and it is the one that was wrong: 0.79% was frame
    // 2388 against frame 2387 alone, not against the detector's local-median
    // baseline, which reads +0.8655%.
    #expect(l.detail.contains("+0.87%"))
    #expect(!l.detail.contains("0.79%"),
            "0.79% is a different baseline rule than the engine applies; #740 requires the engine's")
    #expect(l.detail.contains("0.6616"))
    // Both spaces named, on a lesson whose entire subject is that the two
    // numbers are not the same quantity.
    #expect(l.detail.contains("linear BT.2020"))
    #expect(l.detail.contains("gamma-encoded"))
    #expect(l.origin.contains("#504"))
    #expect(l.origin.contains("#513"))
    #expect(l.origin.contains("#740"))
}

@Test func theLessonIsReportedEvenWhenNoVerdictCanBe() {
    // The lesson is Walk's own measurement, not anybody's taste, so it does not
    // wait on the criteria file.
    // Pinned away from the installed criteria for the same reason as above: this
    // asserts a property of the ABSENCE path, so it must not be able to pass
    // through the stale path instead.
    let report = Coaching.Coach(explicit: URL(fileURLWithPath: "/nonexistent/x.json"),
                                environment: [:],
                                defaultLocation: URL(fileURLWithPath: NSTemporaryDirectory())
                                    .appendingPathComponent("walk-absent-\(UUID().uuidString).json"))
        .report(for: [])
    #expect(!report.available)
    #expect(report.lessons.contains { $0.id == "luminanceIsNotLightning" })
}

// MARK: - the contract, tied to reality

@Test func theCoachingShapeIsDeclaredAndTheVerdictIsDeclaredAbsent() {
    #expect(Walk.capabilities["coach.bands"] == "0.5.0")
    #expect(Walk.capabilities["coach.criteria"] == "0.5.0")
    #expect(Walk.capabilities["coach.evidence"] == "0.5.0")
    #expect(Walk.notImplemented.contains("coach.verdict"))
    let reason = Walk.notImplementedReasons["coach.verdict"] ?? ""
    #expect(reason.contains("#513"))
    #expect(reason.contains("#499"))
    // THE app.proofSheet GAP #513 NAMED. The capability list declared a sheet
    // and said nothing about the sheet not judging — absence indistinguishable
    // from success, in the contract surface built to prevent that.
    #expect(reason.contains("app.proofSheet"),
            "coach.verdict's reason must name app.proofSheet as displaying and not judging")
    #expect(reason.contains(Criteria.environmentKey))
}

@Test func shippingCriteriaInsideTheBuildCannotHappenQuietly() {
    // The contract's prose says "no criteria ship with this build". That is a
    // sentence about a mechanism, so it is TIED to the mechanism here and fails
    // in both directions.
    if Coaching.shippedCriteriaJSON == nil {
        #expect(Walk.notImplemented.contains("coach.verdict"),
                "no criteria ship, so coach.verdict must be declared absent")
    } else {
        #expect(!Walk.notImplemented.contains("coach.verdict"),
                "criteria now ship with Walk — coach.verdict is no longer absent and the contract must say so")
        #expect(Walk.capabilities["coach.verdict"] != nil)
        // And they must actually load, or the build ships a broken judgment.
        #expect(throws: Never.self) {
            _ = try Criteria.parse(Data((Coaching.shippedCriteriaJSON ?? "").utf8),
                                   source: "shipped")
        }
    }
}
