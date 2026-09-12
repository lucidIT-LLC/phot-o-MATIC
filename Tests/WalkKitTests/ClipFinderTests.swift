import Foundation
import Testing
@testable import WalkKit

// ClipFinder is the folder walk that used to live inside the app (#507). These
// tests are the reason it moved: the behaviour is now somewhere a test can reach
// it, and "nothing to scan" is asserted as an ANSWER rather than assumed to be
// an empty array nobody looks at.

private func sandbox(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-clipfinder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not really a video".utf8).write(to: url)
}

@Test func findsVideosInAFolderAndSkipsTheRest() throws {
    try sandbox { dir in
        try touch(dir.appendingPathComponent("GX010036.MP4"))
        try touch(dir.appendingPathComponent("GX010035.mp4"))   // lowercase extension
        try touch(dir.appendingPathComponent("GX010036.THM"))   // GoPro thumbnail
        try touch(dir.appendingPathComponent("notes.txt"))

        let found = ClipFinder.find([dir])
        #expect(found.clips.count == 2)
        #expect(found.clips.map(\.lastPathComponent) == ["GX010035.mp4", "GX010036.MP4"])
        #expect(found.skipped.count == 2)
        #expect(!found.foundNothing)
        #expect(found.directoriesSearched == [dir.standardizedFileURL])
    }
}

@Test func anEmptyFolderIsAnAnswerAndSaysWhichKind() throws {
    try sandbox { dir in
        // Nothing at all in it.
        let empty = ClipFinder.find([dir])
        #expect(empty.foundNothing)
        #expect(empty.verdict.contains("1 folder searched"))
        #expect(empty.verdict.contains("no files in them at all"))

        // Files, but none of them video. A DIFFERENT answer — this is the case
        // the operator hit with .THM sidecars, and reporting it as "empty
        // folder" would be wrong.
        try touch(dir.appendingPathComponent("GX010036.THM"))
        let noVideo = ClipFinder.find([dir])
        #expect(noVideo.foundNothing)
        #expect(noVideo.verdict.contains("none of them video"))
    }
}

@Test func nothingGivenAtAllIsItsOwnVerdict() {
    let found = ClipFinder.find([URL](), options: .init())
    #expect(found.foundNothing)
    #expect(found.verdict.contains("nothing given was a video file"))
    #expect(found.directoriesSearched.isEmpty)
}

@Test func subfoldersAreNotDescendedUnlessAsked() throws {
    try sandbox { dir in
        try touch(dir.appendingPathComponent("top.mp4"))
        try touch(dir.appendingPathComponent("deeper/inner.mp4"))

        // OFF BY DEFAULT IS THE BEHAVIOUR UNDER TEST, not an accident. "Walk
        // this folder" means this folder; a recursive default is how a scan
        // silently becomes a hundred times longer than the person asking meant.
        #expect(ClipFinder.find([dir]).clips.map(\.lastPathComponent) == ["top.mp4"])
        let deep = ClipFinder.find([dir], options: .init(recursive: true))
        #expect(deep.clips.map(\.lastPathComponent).sorted() == ["inner.mp4", "top.mp4"])
    }
}

@Test func filesAndFoldersMixAndDoNotDuplicate() throws {
    try sandbox { dir in
        let a = dir.appendingPathComponent("a.mp4")
        try touch(a)
        // The same file named directly AND reached through the folder.
        let found = ClipFinder.find([dir, a, a])
        #expect(found.clips.count == 1)
    }
}

@Test func aMissingPathIsSkippedNotCrashedOn() throws {
    try sandbox { dir in
        try touch(dir.appendingPathComponent("a.mp4"))
        let found = ClipFinder.find([dir, dir.appendingPathComponent("ghost.mp4")])
        #expect(found.clips.count == 1)
        #expect(found.skipped.contains { $0.lastPathComponent == "ghost.mp4" })
    }
}

@Test func theClipCeilingIsHonoured() throws {
    try sandbox { dir in
        for i in 0..<5 { try touch(dir.appendingPathComponent("clip\(i).mp4")) }
        #expect(ClipFinder.find([dir], options: .init(maximumClips: 2)).clips.count == 2)
    }
}

@Test func clipsSortNumericallyNotLexically() throws {
    try sandbox { dir in
        for n in ["2", "10", "1"] { try touch(dir.appendingPathComponent("clip\(n).mp4")) }
        // A plain string sort puts clip10 before clip2, which reorders a
        // sequence of takes and makes a report read wrong.
        #expect(ClipFinder.find([dir]).clips.map(\.lastPathComponent)
                == ["clip1.mp4", "clip2.mp4", "clip10.mp4"])
    }
}

@Test func thumbnailDirectoryIsACacheNotATemp() {
    let dir = ClipScan.defaultThumbnailDirectory().path
    // The MCP front door returns thumbnail PATHS and the host reads them back
    // after the call returns. A temp sweep between the two would be
    // indistinguishable from a broken thumbnail.
    #expect(dir.contains("Caches"))
    #expect(dir.hasSuffix("Walk/thumbnails"))
    #expect(!dir.contains("/T/"), "a per-boot temp directory is not durable enough for a returned path")
}

@Test func triageOptionsTakeTheFastStrideAndSayNothingIsExact() {
    let o = ClipScan.Options.triage()
    #expect(o.yPlaneStride == 4)
    #expect(o.computeYPlane)
    // The default for a single clip is the exact path; triage is opt-in.
    #expect(ClipScan.Options().yPlaneStride == 1)
}
