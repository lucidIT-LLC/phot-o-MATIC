import Testing
@testable import WalkKit

// The version contract must be able to FAIL. A check that has only ever passed
// is not a check — these tests assert the failure paths, not just the happy one.

@Test func exactMatchPasses() {
    let c = Walk.check(expecting: Walk.version)
    #expect(c.ok)
    #expect(c.detail == "exact match")
}

@Test func walkNewerThanConsumerFails() {
    let c = Walk.check(expecting: "0.1.0")
    #expect(!c.ok)
    #expect(c.detail.contains("NEWER"))
}

@Test func walkOlderThanConsumerFails() {
    let c = Walk.check(expecting: "9.9.9")
    #expect(!c.ok)
    #expect(c.detail.contains("OLDER"))
}

@Test func unparseableVersionFails() {
    #expect(!Walk.check(expecting: "banana").ok)
    #expect(!Walk.check(expecting: "1.2").ok)
    #expect(!Walk.check(expecting: "").ok)
}

@Test func capabilityAndNotImplementedListsAreDisjoint() {
    let caps = Set(Walk.capabilities.keys)
    let not = Set(Walk.notImplemented)
    #expect(caps.intersection(not).isEmpty,
            "a capability cannot be both present and not implemented")
}

// BT.2390: gamma = 1.2 + 0.42 * log10(Lw/1000). The constant that crushed a
// storm foreground to black. If this drifts, the engine is wrong.
@Test func systemGammaMatchesTheStandard() {
    #expect(abs(HLGGrade.systemGamma(targetNits: 1000) - 1.2) < 0.0001)
    #expect(abs(HLGGrade.systemGamma(targetNits: 100) - 0.78) < 0.0001)
    #expect(HLGGrade.systemGamma(targetNits: 100) < 1.0,
            "SDR gamma must be below 1 or shadows are darkened instead of lifted")
}

@Test func neutralLookIsActuallyNeutral() {
    let n = HLGGrade.Look.neutral
    #expect(n.exposure == 1.0)
    #expect(n.contrast == 1.0)
    #expect(n.saturation == 1.0)
    #expect(n.vibrance == 0.0)
}

@Test func anInvalidReadingReportsItselfInvalid() {
    let r = HLGGrade.Reading(r: .nan, g: 0, b: 0, luma: .nan)
    #expect(!r.valid, "NaN must never read as a valid measurement")
}

// MARK: - 0.4.0: the contract must explain itself

// THE DEFECT THIS TEST EXISTS FOR. `ingest.dump` sat in `notImplemented` at
// 0.3.0 as a bare word, while the app walked a folder of eight clips (#507). The
// entry was not wrong so much as unreadable: it was doing duty for "enumerate a
// folder", which existed, and "rank a dump by interest", which did not. A
// one-word denial cannot make that distinction, so the list was believed to say
// something it did not say. Every absence now owes a reason.

@Test func everyAbsentCapabilityCarriesAReason() {
    for name in Walk.notImplemented {
        let reason = Walk.notImplementedReasons[name]
        #expect(reason != nil, "\(name) is declared not-implemented with no reason recorded")
        #expect((reason?.count ?? 0) >= 40,
                "\(name)'s reason is too short to say where the edge actually is")
    }
}

@Test func noReasonIsRecordedForSomethingThatIsImplemented() {
    // The reasons map is not a scratchpad. A reason for a capability that is
    // present would read as a denial of something Walk does.
    let absent = Set(Walk.notImplemented)
    for name in Walk.notImplementedReasons.keys {
        #expect(absent.contains(name),
                "\(name) has a not-implemented reason but is not in notImplemented")
    }
}

@Test func folderScanIsDeclaredAndDumpIsNot() {
    // The exact resolution of #507's contract drift, asserted so it cannot be
    // quietly reversed in either direction: the library walks folders and says
    // so, and it still does not claim to sort them.
    #expect(Walk.capabilities["ingest.folderScan"] == "0.4.0")
    #expect(Walk.notImplemented.contains("ingest.dump"))
    #expect(Walk.notImplemented.contains("ingest.triage"))
    #expect(Walk.notImplementedReasons["ingest.dump"]?.contains("ingest.folderScan") == true,
            "ingest.dump's reason must name what DOES exist, or the same ambiguity returns")
}

@Test func theMCPFrontDoorIsDeclared() {
    #expect(Walk.capabilities["mcp.stdio"] == "0.4.0")
}

@Test func versionAndCapabilityVersionsAgree() {
    // A capability cannot have been introduced by a Walk that does not exist yet.
    for (name, introduced) in Walk.capabilities {
        let c = Walk.check(expecting: introduced)
        #expect(c.ok || c.detail.contains("NEWER"),
                "\(name) claims to have arrived in \(introduced), which is newer than \(Walk.version)")
    }
}
