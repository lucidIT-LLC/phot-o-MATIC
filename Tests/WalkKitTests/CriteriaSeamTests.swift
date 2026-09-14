import Testing
import Foundation
@testable import WalkKit

// THE SEAM ON `Criteria.defaultURL`, AND THE MEASUREMENT THAT FORCED IT.
//
// `Criteria.defaultURL` resolves through `FileManager.urls(for:
// .applicationSupportDirectory, in: .userDomainMask)`, which reads the user
// record from the password database and NOT the `HOME` environment variable.
// MEASURED 2026-09-12 by overriding HOME in a subprocess and watching both runs
// still resolve to the same real path. `WALK_CRITERIA` is no substitute: it
// SELECTS an alternative file and cannot assert an ABSENCE. So before this seam
// existed there was no way to reach the "no criteria installed" state from a
// test without moving the operator's live file.
//
// THE COST OF NOT HAVING IT, and it is not hypothetical.
// `withNoCriteriaTheReportSaysSoAndNamesWhereItLooked` asserts the ABSENCE
// branch and passed for weeks — because the criteria installed on the author's
// machine happened to declare the same version as the build, so the coach
// reported unavailable for a reason that merely LOOKED like the right one. When
// Walk went to 0.5.5 the installed 0.5.0 set was correctly rejected as stale,
// the STALENESS branch rendered instead, and the test failed. It had never
// tested the absence branch in isolation; it was reading host state and getting
// lucky. That is the same defect class as a document that cannot detect its own
// staleness, which is what this whole repository is built around.
//
// Every test below pins its own `defaultLocation` to a directory it creates, so
// none of them can pass or fail because of what is installed on this machine.

private func makeTemporaryDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-seam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A MINIMAL, SELF-CONTAINED criteria set. Deliberately not a copy of the
/// operator's installed file: a fixture that tracks someone else's live
/// document would fail whenever they edited it, which is the host dependence
/// this file exists to remove. `walk` is a parameter because the version
/// relationship is the thing under test.
private func criteriaJSON(walk: String, version: String = "1.0.0") -> String {
    """
    {
      "criteria": {
        "version": "\(version)",
        "walk": "\(walk)",
        "owner": "WalkKit test fixture — NOT photographic judgment, and not Andy's",
        "established": "2026-09-12",
        "note": "Fixture for the defaultLocation seam. One rule, enough to load."
      },
      "rules": [
        {
          "id": "fixture-rule",
          "band": "sellableAsShot",
          "when": [{ "measurement": "vision.lightning", "op": "atLeast", "value": 0.5 }],
          "reason": "A fixture rule. It exists so the file loads, not so it judges.",
          "origin": "WalkKit CriteriaSeamTests, 2026-09-12",
          "nextFlight": "Nothing. This is a fixture."
        }
      ]
    }
    """
}

// MARK: - the seam itself

@Test func theDefaultLocationIsInjectableAndIsWhatGetsSearched() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pinned = dir.appendingPathComponent("criteria.json")

    let r = Criteria.resolve(explicit: nil, environment: [:], defaultLocation: pinned)
    #expect(r.defaultLocation == pinned)
    #expect(r.searched.contains { $0.contains(pinned.path) },
            "the resolution must name the location it actually consulted")
    #expect(!r.searched.contains { $0.contains(Criteria.defaultURL.path) },
            "with a pinned location the real installed path must not be consulted at all")
}

@Test func omittingTheSeamStillUsesTheInstalledLocation() {
    // The seam must not change production behaviour. Nothing is asserted about
    // whether that file EXISTS — that is exactly the host state these tests
    // refuse to depend on — only that it is the path consulted.
    let r = Criteria.resolve(explicit: nil, environment: [:])
    #expect(r.defaultLocation == Criteria.defaultURL)
}

// MARK: - state 1: criteria ABSENT

@Test func withNoCriteriaAnywhereTheReasonIsTheAbsenceBranch() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let absent = dir.appendingPathComponent("criteria.json")
    #expect(!FileManager.default.fileExists(atPath: absent.path))

    let coach = Coaching.Coach(explicit: URL(fileURLWithPath: "/nonexistent/named.json"),
                               environment: [:],
                               defaultLocation: absent)
    #expect(!coach.isReady)
    let report = coach.report(for: [ClipScan.Candidate]())
    #expect(!report.available)
    #expect(report.verdicts.isEmpty)

    let reason = try #require(report.unavailableReason)
    // The absence branch, identified by what #499 and #513 require it to say.
    #expect(reason.contains("no criteria file"))
    #expect(reason.contains("#499"))
    #expect(reason.contains("#513"))
    #expect(reason.contains(Criteria.environmentKey))
    // It must name the location it actually searched, not the installed one.
    #expect(reason.contains(absent.path),
            "the reason must tell the operator where to install a set — the path it looked at")
    #expect(report.searched.contains { $0.contains("/nonexistent/named.json") })
    #expect(report.headline.contains("No coaching verdict rendered"))
}

@Test func absenceIsReachableRegardlessOfWhatIsInstalledOnThisMachine() throws {
    // The point of the whole exercise, asserted directly: this passes whether or
    // not a criteria file is installed, and whether or not it is stale.
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coach = Coaching.Coach(explicit: nil, environment: [:],
                               defaultLocation: dir.appendingPathComponent("nothing-here.json"))
    #expect(coach.criteria == nil)
    #expect(coach.loadError == nil,
            "an absent file is an ABSENCE, never a load error — those are different answers")
}

// MARK: - state 2: criteria PRESENT BUT STALE

@Test func aStaleCriteriaSetIsRejectedAndTheReasonSaysSo() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("criteria.json")

    // The live case, reproduced without the live file: the operator's installed
    // set declares 0.5.0 deliberately (writing 0.5.5 would claim a verification
    // nobody has performed), and this build is newer.
    let staleVersion = "0.5.0"
    #expect(staleVersion != Walk.version,
            "if these ever coincide this test proves nothing and must be re-pointed")
    try Data(criteriaJSON(walk: staleVersion).utf8).write(to: file)

    let coach = Coaching.Coach(explicit: nil, environment: [:], defaultLocation: file)
    // It LOADED. That is the distinction the absence branch cannot make.
    #expect(coach.criteria != nil, "a stale set still parses; staleness is not a parse failure")
    #expect(coach.loadError == nil, "stale is not the same answer as unreadable")
    #expect(!coach.isReady)

    let reason = try #require(coach.unavailableReason)
    #expect(reason.contains("was written against Walk \(staleVersion)"))
    #expect(reason.contains("this build is \(Walk.version)"))
    #expect(reason.contains("re-verify the set and bump its `walk` field deliberately"))
    // And it must NOT be mistaken for the absence branch.
    #expect(!reason.contains("no criteria file"),
            "a present-but-stale set is a different answer from no set at all")

    let report = coach.report(for: [ClipScan.Candidate]())
    #expect(!report.available)
    #expect(report.verdicts.isEmpty, "no verdict is rendered from criteria that do not match")
}

@Test func amatchingCriteriaSetIsAccepted() throws {
    // The gate must be able to PASS as well as fail, or it proves nothing about
    // staleness — it would just be a coach that never works.
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("criteria.json")
    try Data(criteriaJSON(walk: Walk.version).utf8).write(to: file)

    let coach = Coaching.Coach(explicit: nil, environment: [:], defaultLocation: file)
    #expect(coach.isReady, "a set written against this exact build must be accepted")
    #expect(coach.unavailableReason == nil)
    let report = coach.report(for: [ClipScan.Candidate]())
    #expect(report.available)
}

// MARK: - the three states stay distinguishable

@Test func absentAndStaleAndBrokenAreThreeDifferentAnswers() throws {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let absent = dir.appendingPathComponent("absent.json")
    let stale = dir.appendingPathComponent("stale.json")
    let broken = dir.appendingPathComponent("broken.json")
    try Data(criteriaJSON(walk: "0.5.0").utf8).write(to: stale)
    try Data("{ \"criteria\": { \"version\": \"1\" } }".utf8).write(to: broken)

    let reasons = [absent, stale, broken].map {
        Coaching.Coach(explicit: nil, environment: [:], defaultLocation: $0).unavailableReason ?? ""
    }
    #expect(reasons.allSatisfy { !$0.isEmpty })
    #expect(Set(reasons).count == 3,
            "absent, stale and broken must not collapse into one message — swallowing a parse error into 'no criteria' hides the one case where somebody tried")
    #expect(reasons[0].contains("no criteria file"))
    #expect(reasons[1].contains("written against Walk"))
    #expect(reasons[2].contains("present and unusable"))
}

// MARK: - the coach cannot read a photograph, and the contract says so

// MEASURED 2026-09-12. Walk measures stills and shows them; it cannot judge one.
// The gap is not a missing rule, it is a missing PATH — and the obvious path is
// worse than none, which is what these tests pin down.

@Test func theAbsenceOfAStillsVerdictIsDeclared() throws {
    // Without this entry a consumer reads coach.bands / coach.criteria /
    // coach.evidence as covering photographs. That is absence indistinguishable
    // from success, in the surface built to prevent it — the same defect #513
    // recorded when app.proofSheet was declared with no statement that the
    // sheet does not judge.
    #expect(Walk.notImplemented.contains("coach.stills"))
    let reason = try #require(Walk.notImplementedReasons["coach.stills"])
    #expect(reason.contains("vision."), "the reason must name the one selector that DOES transfer")
    #expect(reason.contains("relativeRise"), "and the ones that do not")
    #expect(Walk.capabilities["coach.stills"] == nil)
}

@Test func everyVideoOnlySelectorIsDerivedFromNeighbouringFrames() {
    // The structural claim behind the absence, asserted so it cannot rot: these
    // four selectors read quantities a single photograph cannot have. They are
    // listed in the reason and they must stay listed.
    let reason = Walk.notImplementedReasons["coach.stills"] ?? ""
    for selector in ["relativeRise", "relativeRisePercent", "sigma", "mergedFrames"] {
        #expect(reason.contains(selector), "\(selector) is video-only and the reason must say so")
    }
    // And the two whose NAMES would transfer while their UNITS would not.
    #expect(reason.contains("yMean") && reason.contains("yMax"))
    #expect(reason.contains("code value") || reason.contains("CODE VALUES"))
}

@Test func aFabricatedZeroBandsAPhotographOnAMeasurementItDoesNotHave() throws {
    // THE MEASUREMENT THAT SETTLED THE DESIGN QUESTION, kept as a test so the
    // "just build a Candidate from a still" shortcut cannot be taken quietly
    // later. This asserts the CURRENT, WRONG behaviour deliberately: it is the
    // evidence for why the path must not be built this way, and if someone makes
    // Candidate's video fields optional this test will fail and should be
    // rewritten to assert the fix.
    let json = """
    {
      "criteria": { "version":"1.0.0","walk":"\(Walk.version)","owner":"test fixture","established":"2026-09-12" },
      "rules": [
        { "id":"quiet-frame","band":"notWorthTheTrouble",
          "when":[{"measurement":"relativeRise","op":"atMost","value":0.01}],
          "reason":"A rule an author might reasonably write for video.",
          "origin":"CriteriaSeamTests","nextFlight":"n/a" }
      ]
    }
    """
    let coach = Coaching.Coach(criteria: try Criteria.parse(Data(json.utf8), source: "fixture"))

    // A still expressed the only way the coach can currently accept one. There
    // is no baseline for a photograph, so relativeRise here is FABRICATED.
    let asIfStill = ClipScan.Candidate(
        frame: 0, timecode: "00:00:00:00", time: 0, ciLuma: 0.5, baseline: 0, delta: 0,
        relativeRise: 0, sigma: 0, mergedFrames: 1,
        yMean: nil, yMax: nil, yClipped: false,
        confidences: ["lightning": 0.01], topLabels: [],
        classifyMilliseconds: nil, thumbnail: nil)

    let report = coach.report(for: [asIfStill])
    let verdict = try #require(report.verdicts.first)
    #expect(verdict.band == .notWorthTheTrouble,
            "a photograph condemned by a number that does not exist for it")
    let evidence = try #require(verdict.evidence.first)
    #expect(evidence.measurement == "relativeRise")
    #expect(evidence.measured == 0.0)
    #expect(evidence.held, "the fabricated zero satisfied the condition — the audit trail looks complete and is not")

    // And the contrast that shows the mechanism already exists and works: an
    // UNMEASURED value is nil, and a rule reading it does not fire.
    #expect(Criteria.value(of: .yMean, on: asIfStill) == nil)
    #expect(Criteria.value(of: .relativeRise, on: asIfStill) == 0.0,
            "non-optional, so it cannot report 'unmeasured' the way a nil confidence can")
}
