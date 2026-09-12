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
