import Foundation
import Testing
@testable import WalkKit

// Task #1013, Smith's audit of this repository. P2 and P3 are the same defect in
// two places: a failure that reads exactly like a choice or an empty answer.
// These tests make each failure produce a REASON, and prove the reason reaches
// the verdict a person reads.

private func sandbox(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-failures-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        // Restore permission first or the sandbox cannot be removed.
        if let e = FileManager.default.enumerator(atPath: dir.path) {
            while let p = e.nextObject() as? String {
                chmod(dir.appendingPathComponent(p).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not really a video".utf8).write(to: url)
}

// MARK: - P2: an unreadable folder is not an empty one

@Test func anUnreadableFolderIsNamedWithItsReasonNotReportedEmpty() throws {
    try sandbox { dir in
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try touch(locked.appendingPathComponent("GX010001.MP4"))
        #expect(chmod(locked.path, 0) == 0)

        let clips = ClipFinder.find([locked])
        #expect(clips.foundNothing)
        #expect(clips.unreadable.count == 1)
        #expect(clips.unreadable.first?.reason.contains("permission denied") == true)
        #expect(clips.verdict.contains("could not be read"))
        // The exact wording that used to come back for an unreadable folder,
        // indistinguishable from a genuinely empty one.
        #expect(!clips.verdict.contains("no files in them at all"))

        // Same traversal, same answer, from the other finder (P1).
        let media = MediaFinder.find([locked])
        #expect(media.unreadable.count == 1)
        #expect(media.verdict.contains("could not be read"))
        #expect(!media.verdict.contains("no files in them at all"))
    }
}

@Test func anUnreadableSubfolderInARecursiveWalkIsRecordedAndTheWalkContinues() throws {
    try sandbox { dir in
        try touch(dir.appendingPathComponent("top.mp4"))
        let locked = dir.appendingPathComponent("deeper", isDirectory: true)
        try touch(locked.appendingPathComponent("inner.mp4"))
        #expect(chmod(locked.path, 0) == 0)

        let found = ClipFinder.find([dir], options: .init(recursive: true))
        #expect(found.clips.map(\.lastPathComponent) == ["top.mp4"])
        #expect(found.unreadable.map { $0.url.lastPathComponent } == ["deeper"])
        #expect(found.unreadable.first?.reason.contains("permission denied") == true)
        #expect(found.verdict.contains("1 clip to scan"))
        #expect(found.verdict.contains("could not be read"))
    }
}

@Test func aReadableEmptyFolderStillSaysEmptyAndNothingElse() throws {
    try sandbox { dir in
        let found = ClipFinder.find([dir])
        #expect(found.unreadable.isEmpty)
        #expect(found.verdict.contains("no files in them at all"))
        #expect(!found.verdict.contains("could not be read"))
    }
}

@Test func bothFindersAgreeOnWhatAFolderHolds() throws {
    try sandbox { dir in
        try touch(dir.appendingPathComponent("a.mp4"))
        try touch(dir.appendingPathComponent("b.MOV"))
        try touch(dir.appendingPathComponent("c.jpg"))
        try touch(dir.appendingPathComponent("sub/d.mp4"))
        for recursive in [false, true] {
            let opts = ClipFinder.Options(recursive: recursive)
            let clips = ClipFinder.find([dir], options: opts).clips.map(\.path)
            let media = MediaFinder.find([dir], options: opts).clips.map(\.url.path)
            #expect(clips == media, "recursive=\(recursive)")
        }
    }
}

// MARK: - P3: a failed stage is recorded, not dropped

// Probe takes a reader, and the known-answer clip is the only real video this
// suite can name, so these three are skipped — visibly — where it is absent.
@Test(.enabled(if: KnownAnswer.available))
func probeAsksNothingAndRecordsNothingWhenNothingIsRequested() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)
    let p = await ClipScan.probe(reader, frame: 0, classifier: nil, thumbnailTo: nil)
    #expect(p.labels == nil)
    #expect(p.failures.isEmpty)
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(2)))
func aFrameThatCannotBeDecodedIsRecordedAsADecodeFailure() async throws {
    let reader = try await VideoReader(url: KnownAnswer.url)
    let p = await ClipScan.probe(reader, frame: 10_000_000, classifier: Classifier(),
                                 thumbnailTo: nil)
    #expect(p.labels == nil)
    #expect(p.failures.map(\.stage) == [.decode])
    #expect(p.failures.first.map { !$0.reason.isEmpty } == true)
}

@Test(.enabled(if: KnownAnswer.available), .timeLimit(.minutes(2)))
func aThumbnailThatCannotBeWrittenIsRecordedAndClassificationStillLands() async throws {
    try await withSandbox { dir in
        // A FILE where the thumbnail's parent directory should be: the write
        // cannot succeed, and it used to vanish into `try?`.
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let reader = try await VideoReader(url: KnownAnswer.url)
        let p = await ClipScan.probe(reader, frame: 2347, classifier: Classifier(),
                                     thumbnailTo: blocker.appendingPathComponent("f.png"))
        #expect(p.labels != nil)
        #expect(p.thumbnail == nil)
        #expect(p.failures.map(\.stage) == [.thumbnail])
    }
}

private func withSandbox(_ body: (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
