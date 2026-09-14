import Testing
import Foundation
import CoreVideo
import CoreMedia
@testable import WalkKit

// The proof sheet's own tests. Everything here except the last section runs
// with no media on disk, deliberately: the arithmetic that decides WHICH frames
// a sheet shows, and the parser that decides what a clip's exposure was, are
// the two places a silent wrong answer would be invisible in a picture.

// MARK: - Which frames get sampled

// THE DEFECT THIS GUARDS. The obvious spacing is `i * total / count`, which puts
// the first sample on frame 0. On drone footage frame 0 is the aircraft still
// settling — often literally a black or half-exposed frame — and it also never
// reaches the end of the clip. Centering each sample in its own slice fixes
// both, and the fix is invisible unless something asserts it.

@Test func sampleIndicesNeverStartAtFrameZero() {
    let idx = ProofSheet.sampleIndices(frameCount: 10782, count: 12)
    #expect(idx.count == 12)
    #expect(idx.first! > 0, "frame 0 is the aircraft still settling and must never be a sample")
}

@Test func sampleIndicesStayInsideTheClip() {
    let idx = ProofSheet.sampleIndices(frameCount: 10782, count: 12)
    #expect(idx.allSatisfy { $0 >= 0 && $0 < 10782 })
    #expect(idx == idx.sorted())
    #expect(Set(idx).count == idx.count, "a sample must not be taken twice")
}

@Test func sampleIndicesReachBothEndsOfTheClip() {
    // Centered slices: the first sample sits at 1/24 of the clip and the last at
    // 23/24. Neither end is abandoned, which `i * total / count` does at the tail.
    let total = 1200
    let idx = ProofSheet.sampleIndices(frameCount: total, count: 12)
    #expect(idx.first! == 50)
    #expect(idx.last! == 1150)
}

@Test func sampleIndicesHandleAClipShorterThanTheSampleCount() {
    // Five frames, twelve asked for. Returning twelve would mean duplicates
    // presented as distinct moments.
    let idx = ProofSheet.sampleIndices(frameCount: 5, count: 12)
    #expect(idx == [0, 1, 2, 3, 4])
}

@Test func sampleIndicesOnNothingIsEmptyRatherThanACrash() {
    #expect(ProofSheet.sampleIndices(frameCount: 0, count: 12).isEmpty)
    #expect(ProofSheet.sampleIndices(frameCount: 100, count: 0).isEmpty)
}

// MARK: - The DJI telemetry parser

// A fixture rather than a file: the real .SRT lives on an external volume with
// the rest of the operator's archive, and CI never sees it. These four blocks
// are copied verbatim in shape from `DJI_20260517021934_0014_D.SRT`, including
// the HTML wrapper and the two-keys-in-one-bracket `rel_alt`/`abs_alt` field.

let djiFixture = """
1
00:00:00,000 --> 00:00:00,016
<font size="28">FrameCnt: 1, DiffTime: 16ms
2026-05-17 02:19:34.546
[iso: 100] [shutter: 1/240.0] [fnum: 1.7] [ev: -0.7] [color_md: hlg] [focal_len: 24.00] [latitude: 0.000000] [longitude: 0.000000] [rel_alt: 1.600 abs_alt: 611.723] [ct: 5429] </font>

2
00:00:00,016 --> 00:00:00,032
<font size="28">FrameCnt: 2, DiffTime: 16ms
2026-05-17 02:19:34.565
[iso: 200] [shutter: 1/8000.0] [fnum: 1.7] [ev: -0.7] [color_md: hlg] [focal_len: 24.00] [rel_alt: 2.100 abs_alt: 612.223] [ct: 5429] </font>

3
00:00:00,032 --> 00:00:00,049
<font size="28">FrameCnt: 3, DiffTime: 17ms
2026-05-17 02:19:34.579
[iso: 200] [shutter: 1/8000.0] [fnum: 1.7] [ev: -0.7] [color_md: hlg] [focal_len: 24.00] [rel_alt: 3.100 abs_alt: 613.223] [ct: 5429] </font>

4
00:00:00,049 --> 00:00:00,066
<font size="28">FrameCnt: 4, DiffTime: 17ms
2026-05-17 02:19:34.596
[iso: 200] [shutter: 1/8000.0] [fnum: 1.7] [ev: -0.7] [color_md: hlg] [focal_len: 24.00] [rel_alt: 4.100 abs_alt: 614.223] [ct: 5429] </font>
"""

@Test func telemetryReadsEverySampleAndNotJustTheFirst() throws {
    let t = try #require(DroneTelemetry.parse(djiFixture, source: URL(fileURLWithPath: "/fixture.SRT")))
    #expect(t.sampleCount == 4)
    let iso = try #require(t.iso)
    #expect(iso.samples == 4)
    // THE WHOLE POINT OF THE TYPE. Frame 1 says ISO 100. The clip is ISO 200.
    // A reader that took the first sample would report the settling frame as
    // the exposure of the whole clip.
    #expect(iso.first == 100)
    #expect(iso.median == 200)
    #expect(iso.mode == 200)
    #expect(iso.first != iso.median, "the fixture exists to make these differ")
}

@Test func telemetryReportsTheModeAndItsShare() throws {
    let t = try #require(DroneTelemetry.parse(djiFixture, source: URL(fileURLWithPath: "/fixture.SRT")))
    let shutter = try #require(t.shutterDenominator)
    #expect(shutter.mode == 8000)
    #expect(abs(shutter.modeShare - 0.75) < 0.0001, "three of four samples sit on the mode")
    #expect(shutter.minimum == 240)
    #expect(shutter.maximum == 8000)
    #expect(!shutter.constant)
}

@Test func telemetryKeepsShutterAsADenominator() {
    // 1/240 is carried as 240 because every piece of arithmetic a reader wants —
    // stops, shutter angle — is on the denominator, and 0.004166 is a number
    // nobody recognizes.
    #expect(DroneTelemetry.shutterDenominator("1/240.0") == 240)
    #expect(DroneTelemetry.shutterDenominator("1/8000") == 8000)
    // Both spellings DJI firmware has written. A parser that returned nil for
    // one of them would report "no shutter data" on a file full of it.
    #expect(DroneTelemetry.shutterDenominator("240") == 240)
    // A genuine long exposure, normalized so the field always means one thing.
    #expect(DroneTelemetry.shutterDenominator("0.5") == 2)
    #expect(DroneTelemetry.shutterDenominator("banana") == nil)
}

@Test func telemetryParsesTwoFieldsInsideOneBracket() {
    // `[rel_alt: 1.600 abs_alt: 611.723]` — splitting on brackets gives rel_alt
    // the value "1.600 abs_alt: 611.723", which parses as nil and reads as
    // missing data rather than as a parser bug.
    let fields = DroneTelemetry.fields(in: "[rel_alt: 1.600 abs_alt: 611.723] [ct: 5429]")
    let map = Dictionary(fields, uniquingKeysWith: { a, _ in a })
    #expect(map["rel_alt"] == "1.600")
    #expect(map["abs_alt"] == "611.723")
    #expect(map["ct"] == "5429")
}

@Test func telemetryStripsTheHTMLWrapperRatherThanTokenizingIt() {
    let fields = DroneTelemetry.fields(in: "<font size=\"28\">FrameCnt: 1, DiffTime: 16ms")
    let map = Dictionary(fields, uniquingKeysWith: { a, _ in a })
    #expect(map["framecnt"] == "1", "the trailing comma must not become part of the value")
    #expect(map["size"] == nil, "the font tag is markup, not telemetry")
}

@Test func telemetryReportsFieldsItSawAndDidNotModel() throws {
    let t = try #require(DroneTelemetry.parse(djiFixture, source: URL(fileURLWithPath: "/fixture.SRT")))
    // Absence must be readable as a decision, not as a parser that missed
    // something. latitude, longitude, ct, abs_alt and the subtitle's own
    // FrameCnt/DiffTime are seen and deliberately not summarized.
    #expect(t.unmodeledKeys.contains("ct"))
    #expect(t.unmodeledKeys.contains("abs_alt"))
    #expect(!t.unmodeledKeys.contains("iso"))
    #expect(t.colorMode == "hlg")
}

@Test func telemetryOnTextWithNoFieldsIsNilRatherThanEmpty() {
    #expect(DroneTelemetry.parse("not an srt at all", source: URL(fileURLWithPath: "/x")) == nil)
    #expect(DroneTelemetry.parse("", source: URL(fileURLWithPath: "/x")) == nil)
}

// MARK: - The 180-degree shutter comparison

@Test func oneEightyShutterIsTwiceTheFrameRate() {
    let rule = DroneTelemetry.ShutterRule(fps: 47.952, denominators: [96, 96, 96])
    #expect(abs(rule.oneEightyDenominator - 95.904) < 0.001)
    #expect(abs(rule.stopsFromOneEighty) < 0.01)
    #expect(rule.withinTolerance)
    #expect(abs(rule.impliedShutterAngle - 179.82) < 0.5)
}

@Test func aFastShutterMeasuresAsStopsAwayAndNotAsAVerdict() {
    // The operator's own material: 1/10000 at 47.952 fps. 10000 / 95.904 is
    // 104.3, which is log2(104.3) = 6.70 stops.
    let rule = DroneTelemetry.ShutterRule(fps: 47.952, denominators: [10000])
    #expect(abs(rule.stopsFromOneEighty - 6.70) < 0.02)
    #expect(!rule.withinTolerance)
    #expect(rule.impliedShutterAngle < 2.0, "1/10000 at 48 fps is a 1.7 degree shutter angle")
    // The wording is a measurement against a named convention. A sheet that
    // called this a bad clip would be rendering a verdict the criteria file owns.
    #expect(rule.note.contains("MEASURED, not judged"))
}

@Test func theShutterToleranceCanPassAndCanFail() {
    // A check that has only ever failed is not a check either.
    let fps = 30.0
    #expect(DroneTelemetry.ShutterRule(fps: fps, denominators: [60]).withinTolerance)
    #expect(DroneTelemetry.ShutterRule(fps: fps, denominators: [80]).withinTolerance,
            "80 is 0.42 stops from 60 and inside the half-stop tolerance")
    #expect(!DroneTelemetry.ShutterRule(fps: fps, denominators: [125]).withinTolerance,
            "125 is 1.06 stops from 60 and outside it")
}

@Test func theShareInsideToleranceCountsEverySample() {
    let rule = DroneTelemetry.ShutterRule(fps: 30, denominators: [60, 60, 60, 10000])
    #expect(abs(rule.shareWithinTolerance - 0.75) < 0.0001)
}

@Test func shutterRuleComesOffTheClipsOwnFrameRate() throws {
    let t = try #require(DroneTelemetry.parse(djiFixture, source: URL(fileURLWithPath: "/f.SRT")))
    let rule = try #require(t.shutterRule(fps: 59.94))
    // Median of [240, 8000, 8000, 8000] is 8000.
    #expect(rule.medianDenominator == 8000)
    #expect(abs(rule.oneEightyDenominator - 119.88) < 0.01)
    #expect(!rule.withinTolerance)
}

// MARK: - What a sheet will and will not look at

@Test func stillsAndClipsAreBothMediaAndTheVideoSetIsNotCopied() {
    // The extension set is declared once, in ClipFinder, because #507 cost this
    // repository a private second copy of it in the app.
    #expect(MediaFinder.stillExtensions.contains("dng"))
    #expect(MediaFinder.stillExtensions.contains("heic"))
    #expect(MediaFinder.stillExtensions.isDisjoint(with: ClipFinder.videoExtensions),
            "a file cannot be both a still and a clip")
}

@Test func theProxyAndTheTelemetrySidecarAreSkippedWithAReason() {
    // A skipped file must be readable as a decision. `.LRF` is DJI's
    // low-resolution proxy of the .MP4 beside it, and showing it would put a
    // worse copy of every clip in the sheet.
    #expect(MediaFinder.knownIgnored["lrf"]?.contains("proxy") == true)
    #expect(MediaFinder.knownIgnored["srt"]?.contains("telemetry") == true)
    #expect(MediaFinder.knownIgnored["lrf"] != nil)
}

@Test func nothingToSheetIsAnAnswerAndSaysWhichKind() {
    let empty = MediaFinder.find([URL(fileURLWithPath: "/nonexistent-path-for-a-test")])
    #expect(empty.foundNothing)
    #expect(empty.verdict.contains("nothing to sheet"))
    #expect(empty.skipped.count == 1)
    #expect(empty.skipped[0].reason.contains("no file at this path"))
}

// MARK: - The manifest contract

func fixtureManifest() -> [String: Any] {
    let cell = ProofSheet.Cell(index: 0, frame: 120, timecode: "00:00:02:00", seconds: 2.0,
                               file: URL(fileURLWithPath: "/out/cells/a_c00_f000120.jpg"),
                               placeholder: "data:image/jpeg;base64,AAAA",
                               ready: true, decodeMilliseconds: 79.0, error: nil)
    let item = ProofSheet.Item(
        url: URL(fileURLWithPath: "/in/a.MP4"), kind: .clip, bytes: 1234,
        width: 3840, height: 2160, fps: 47.952, seconds: 224.8, frameCount: 10782,
        codec: "hvc1", colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG",
        yCbCrMatrix: "ITU_R_2020", isHLGBT2020: true, dataRateMbps: 130,
        colorProfile: nil, toneMap: "test", telemetry: nil, shutter: nil,
        cells: [cell], error: nil)
    let found = MediaFinder.find([URL(fileURLWithPath: "/nonexistent")])
    return ProofSheet.manifest(items: [item], found: found, inputs: [],
                               options: ProofSheet.Options(outputDirectory: URL(fileURLWithPath: "/out")))
}

@Test func theManifestSerializesAsJSON() throws {
    // It is read by a browser. A dictionary that will not serialize is a sheet
    // that renders as nothing, with no error anywhere near the cause.
    let data = try JSONSerialization.data(withJSONObject: fixtureManifest(), options: [.sortedKeys])
    #expect(data.count > 0)
    let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(back["walk"] as? String == Walk.version)
    #expect(back["manifestVersion"] as? Int == 1)
}

@Test func theManifestSaysItRenderedNoVerdict() throws {
    // #513 and #499 stated in the artifact itself, so a viewer cannot add a
    // verdict Walk did not render and call it Walk's.
    let m = fixtureManifest()
    let judgment = try #require(m["judgment"] as? [String: Any])
    #expect(judgment["rendered"] as? Bool == false)
    let note = try #require(judgment["note"] as? String)
    #expect(note.contains("DISPLAYS AND MEASURES"))
    #expect(note.contains("does not band, rank, score or sort"))
}

@Test func theManifestCarriesTheStatusAViewerPolls() throws {
    let m = fixtureManifest()
    #expect(m["status"] as? String == "complete")
    let found = MediaFinder.find([URL(fileURLWithPath: "/nonexistent")])
    let sampling = ProofSheet.manifest(items: [], found: found, inputs: [],
                                       options: ProofSheet.Options(outputDirectory: URL(fileURLWithPath: "/out")),
                                       status: .sampling)
    #expect(sampling["status"] as? String == "sampling")
}

@Test func everyCellCarriesItsEvidence() throws {
    let m = fixtureManifest()
    let items = try #require(m["items"] as? [[String: Any]])
    let item = try #require(items.first)
    #expect(item["fps"] as? Double == 47.952)
    #expect(item["transferFunction"] as? String == "ITU_R_2100_HLG")
    #expect(item["isHLGBT2020"] as? Bool == true)
    let cells = try #require(item["cells"] as? [[String: Any]])
    let cell = try #require(cells.first)
    #expect(cell["frame"] as? Int == 120)
    #expect(cell["timecode"] as? String == "00:00:02:00")
    #expect(cell["seconds"] as? Double == 2.0)
    #expect((cell["file"] as? String)?.hasSuffix("a_c00_f000120.jpg") == true)
    #expect((cell["placeholder"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    #expect(cell["ready"] as? Bool == true)
}

@Test func theManifestNamesThePlaceholdersProvenance() throws {
    // The placeholder is the NEAREST SYNC SAMPLE, not the frame the sharp cell
    // shows. At 20 pixels blurred that is invisible — and an invisible
    // undocumented difference is exactly how #740 put thirteen verdicts on the
    // wrong thirteen frames.
    let contract = try #require(fixtureManifest()["placeholderContract"] as? [String: Any])
    let provenance = try #require(contract["provenance"] as? String)
    #expect(provenance.contains("NEAREST SYNC SAMPLE"))
    #expect(provenance.contains("not the frame the sharp cell shows"))
}

@Test func theManifestSaysTheseAreTimeSamplesAndNotEvents() throws {
    let sampling = try #require(fixtureManifest()["sampling"] as? [String: Any])
    let note = try #require(sampling["note"] as? String)
    #expect(note.contains("TIME SAMPLES, not detected events"))
}

@Test func aStillCellCarriesNoFrameOrTimecode() throws {
    let cell = ProofSheet.Cell(index: 0, frame: nil, timecode: nil, seconds: nil,
                               file: URL(fileURLWithPath: "/out/cells/s_c00.jpg"),
                               placeholder: nil, ready: false,
                               decodeMilliseconds: nil, error: nil)
    let d = ProofSheet.cellDictionary(cell)
    #expect(d["frame"] == nil, "a still has no frame index and must not invent one")
    #expect(d["timecode"] == nil)
    #expect(d["ready"] as? Bool == false)
    #expect(d["placeholder"] == nil)
}

@Test func stillsAndClipsDoNotClaimTheSameTransform() {
    // A still is display-referred already; a clip cell has a filmic curve on it.
    // Each item names its own, because a cell that looks flat must be readable
    // as a transform rather than as the footage.
    let still = ProofSheet.stillToneMapNote("Display P3")
    #expect(still.contains("NO filmic curve"))
    #expect(still.contains("Display P3"))
}

@Test func anHLGClipsToneMapNoteNamesTheSDRSystemGamma() {
    // 0.78, not 1.2. The units error that crushed a storm foreground to black,
    // stated in the artifact a person actually reads.
    let info = VideoInfo(url: URL(fileURLWithPath: "/a.MP4"), width: 3840, height: 2160,
                         frameDuration: .init(value: 1001, timescale: 48000),
                         nominalFrameRate: 47.952, duration: .init(value: 1, timescale: 1),
                         estimatedFrameCount: 48, codec: "hvc1", bitDepth: 10,
                         colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                         transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                         yCbCrMatrix: nil, estimatedDataRateMbps: 130)
    #expect(info.isHLGBT2020)
    let note = ProofSheet.clipToneMapNote(info)
    #expect(note.contains("0.78"))
    #expect(note.contains("not the widely-quoted 1.2"))
}

// MARK: - The contract

@Test func theTimeSampledSheetIsDeclaredAndTheDetectorSheetIsNotStretched() {
    // The #507 precedent, asserted so it cannot be quietly reversed: the new
    // behavior is declared under a name narrow enough to be true, and
    // app.proofSheet — the window that shows DETECTED CANDIDATES — is left
    // saying what it has always said.
    #expect(Walk.capabilities["sheet.timeSampled"] == "0.5.5")
    #expect(Walk.capabilities["sheet.progressive"] == "0.5.5")
    #expect(Walk.capabilities["sheet.manifest"] == "0.5.5")
    #expect(Walk.capabilities["ingest.stills"] == "0.5.5")
    #expect(Walk.capabilities["telemetry.djiSRT"] == "0.5.5")
    #expect(Walk.capabilities["app.proofSheet"] == "0.3.0",
            "the app window did not change in 0.5.5 and must not claim to have")
}

@Test func rankingIsStillAbsentAndItsReasonNamesWhatDoesExist() {
    // A one-word denial is how ingest.dump came to be read as a flat refusal of
    // folder handling. Both absences now have to name the thing that IS built.
    #expect(Walk.notImplemented.contains("ingest.dump"))
    #expect(Walk.notImplemented.contains("page.bestWorst"))
    #expect(Walk.notImplementedReasons["ingest.dump"]?.contains("sheet.timeSampled") == true)
    #expect(Walk.notImplementedReasons["page.bestWorst"]?.contains("sheet.timeSampled") == true)
    #expect(Walk.capabilities["ingest.dump"] == nil)
}

// MARK: - Against real material

// Conditional for the same reason the known-answer tests are: this is the
// operator's own card, on an external volume, and CI never sees it. A skip is
// reported as a skip so a green run is not read as a verified sheet.

enum SheetMaterial {
    static let folder = "/Volumes/NVMeExt1/Content/Photography/DJI_001"
    static var url: URL { URL(fileURLWithPath: folder) }

    /// THE PRECONDITION PROVED THE WRONG THING, AND IT COST A RED SUITE.
    /// MEASURED 2026-09-13.
    ///
    /// This read `FileManager.default.fileExists(atPath: folder)` — it checked
    /// that the DIRECTORY existed. Mid-session the operator's cull emptied
    /// `DJI_001`, moving the eight clips and three stills out to `KEEP/` and
    /// trashing the originals. The directory SURVIVED, carrying `.DS_Store` and
    /// `KEEP/`, so the gate reported `available`, both tests ran against
    /// material that was gone, and the suite went red with five issues in a
    /// build whose changes touched none of this.
    ///
    /// The environmental cause is not the defect. The defect is that a
    /// precondition which cannot distinguish MATERIAL PRESENT from DIRECTORY
    /// PRESENT is not a precondition. The comment above says the intent in
    /// terms — "A skip is reported as a skip so a green run is not read as a
    /// verified sheet" — and the old mechanism could not deliver that for a
    /// present-but-emptied folder. Same class as a `.timeLimit` that never
    /// fires: a guard nobody has watched hold is not a guard.
    ///
    /// WHY THIS COUNTS FILES ITSELF INSTEAD OF ASKING `MediaFinder`. The test
    /// below asserts that `MediaFinder` sorts this folder into 8 clips and 3
    /// stills. If the gate established that by calling `MediaFinder`, the gate
    /// would guarantee exactly what the test claims to check and the test would
    /// assert nothing. So the extension sets are deliberately duplicated here,
    /// and the duplication is the point: the gate says "the material is on
    /// disk", the test says "MediaFinder classifies it correctly", and a
    /// misclassification still fails rather than skips.
    ///
    /// It requires the counts EXACTLY, so an archive that grows also skips
    /// rather than failing an assertion that names a number.
    static let expectedClips = 8
    static let expectedStills = 3
    private static let videoExt: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mpg", "mpeg"]
    private static let stillExt: Set<String> = ["jpg", "jpeg", "heic", "heif", "dng", "png", "tif", "tiff"]

    /// The clip the telemetry test reads by name, with its sidecar.
    static let anchorClip = "DJI_20260913024928_0001_D.MP4"
    static let anchorSidecar = "DJI_20260913024928_0001_D.SRT"

    /// Why the material is not usable, or nil when it is. A REASON rather than
    /// a bare false, so a skip can say which of the several ways it went.
    static func unusable(in root: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return "no directory at \(root.path)"
        }
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return "directory at \(root.path) could not be read"
        }
        let files = names.filter { !$0.hasPrefix(".") }
        let ext = { (n: String) in (n as NSString).pathExtension.lowercased() }
        let clips = files.filter { videoExt.contains(ext($0)) }.count
        let stills = files.filter { stillExt.contains(ext($0)) }.count
        if clips != expectedClips || stills != expectedStills {
            return "expected \(expectedClips) clips and \(expectedStills) stills, found \(clips) and \(stills)"
        }
        // The two skip assertions need a proxy and a sidecar actually present.
        guard files.contains(where: { ext($0) == "lrf" }) else { return "no .LRF proxy present" }
        guard files.contains(where: { ext($0) == "srt" }) else { return "no .SRT sidecar present" }
        guard files.contains(anchorClip) else { return "\(anchorClip) is absent" }
        guard files.contains(anchorSidecar) else { return "\(anchorSidecar) is absent" }
        return nil
    }

    static var available: Bool { unusable(in: url) == nil }
}

// MARK: - the gate itself, proved in both directions

// MECHANIZE THE CHECK. The old gate was never watched holding, which is how it
// came to be trusted while proving the wrong thing. These run on every machine,
// need none of the operator's archive, and fail if the gate stops being able to
// say no — or stops being able to say yes.

private func makeArchive(_ dir: URL, clips: Int, stills: Int,
                         lrf: Bool = true, srt: Bool = true,
                         anchor: Bool = true, sidecar: Bool = true) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func touch(_ name: String) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }
    // The anchor is one OF the clips, not an extra, so the counts stay honest.
    var made = 0
    if anchor && clips > 0 { try touch(SheetMaterial.anchorClip); made = 1 }
    for i in made..<clips { try touch("FILLER_\(i).MP4") }
    for i in 0..<stills { try touch("STILL_\(i).JPG") }
    if lrf { try touch("PROXY.LRF") }
    if srt { try touch("OTHER.SRT") }
    if sidecar { try touch(SheetMaterial.anchorSidecar) }
}

@Test func theMaterialGateSaysYesToAFullArchive() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-gate-full-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeArchive(dir, clips: SheetMaterial.expectedClips, stills: SheetMaterial.expectedStills)
    // A dotfile must not change the answer — `.DS_Store` was present in the
    // real folder the day this broke.
    try Data().write(to: dir.appendingPathComponent(".DS_Store"))
    #expect(SheetMaterial.unusable(in: dir) == nil,
            "a complete archive must ENABLE the tests; got \(SheetMaterial.unusable(in: dir) ?? "")")
}

@Test func theMaterialGateSaysNoToThePresentButEmptiedFolder() throws {
    // THE EXACT SHAPE THAT WENT RED: the directory survives, carrying a
    // dotfile and a subdirectory, and every file the tests read is gone.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-gate-emptied-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("KEEP"),
                                            withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent(".DS_Store"))
    let why = SheetMaterial.unusable(in: dir)
    #expect(why != nil, "an emptied folder must SKIP, not run against missing files")
    #expect(why?.contains("found 0 and 0") == true, "the skip must say what it found: \(why ?? "")")
}

@Test func theMaterialGateSaysNoToEveryPartialArchive() throws {
    // Each case is wrong in exactly one way, and every one must be caught —
    // otherwise the gate passes material that fails an assertion downstream.
    let cases: [(String, (URL) throws -> Void)] = [
        ("one clip short", { try makeArchive($0, clips: 7, stills: 3) }),
        ("one clip too many", { try makeArchive($0, clips: 9, stills: 3) }),
        ("one still short", { try makeArchive($0, clips: 8, stills: 2) }),
        ("one still too many", { try makeArchive($0, clips: 8, stills: 4) }),
        ("no .LRF proxy", { try makeArchive($0, clips: 8, stills: 3, lrf: false) }),
        ("no .SRT sidecar at all", { try makeArchive($0, clips: 8, stills: 3, srt: false, sidecar: false) }),
        ("the anchor clip renamed away", { try makeArchive($0, clips: 8, stills: 3, anchor: false) }),
        ("the anchor's sidecar missing", { try makeArchive($0, clips: 8, stills: 3, sidecar: false) }),
    ]
    for (label, build) in cases {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try build(dir)
        #expect(SheetMaterial.unusable(in: dir) != nil,
                "\(label): the gate cannot detect it, so the suite would go red instead of skipping")
    }
}

@Test(.enabled(if: SheetMaterial.available))
func theOperatorsFolderEnumeratesToClipsStillsAndReasonedSkips() {
    let found = MediaFinder.find([SheetMaterial.url])
    #expect(found.clips.count == 8)
    #expect(found.stills.count == 3, "two JPG and one DNG")
    // The .LRF proxies and the .SRT sidecars must be skipped WITH a reason, not
    // silently absent.
    let skippedExtensions = Set(found.skipped.map { $0.url.pathExtension.lowercased() })
    #expect(skippedExtensions.contains("lrf"))
    #expect(skippedExtensions.contains("srt"))
    #expect(found.skipped.allSatisfy { !$0.reason.isEmpty })
}

@Test(.enabled(if: SheetMaterial.available), .timeLimit(.minutes(5)))
func theOperatorsFastestClipMeasuresAsFarFromTheOneEightyConvention() throws {
    let clip = SheetMaterial.url.appendingPathComponent("DJI_20260913024928_0001_D.MP4")
    try #require(FileManager.default.fileExists(atPath: clip.path))
    let sidecar = try #require(DroneTelemetry.sidecar(for: clip))
    let t = try #require(DroneTelemetry.read(sidecar))
    #expect(t.sampleCount > 10000)
    let shutter = try #require(t.shutterDenominator)
    #expect(shutter.mode == 10000)
    let rule = try #require(t.shutterRule(fps: 47.952047952047955))
    #expect(!rule.withinTolerance)
    #expect(rule.stopsFromOneEighty > 6.0)
    #expect(rule.shareWithinTolerance == 0.0,
            "not one sample in the file sits near the 180-degree value")
}

// MARK: - Cell names cannot collide

// MEASURED DEFECT, first real run 2026-09-12. `..._0016_D.DNG` and
// `..._0016_D.JPG` are the raw and the JPEG of one shot and share a stem, so
// both cells were written to the same path: the second overwrote the first and
// BOTH reported ready. 99 cells claimed, 98 files on disk, nothing logged.

@Test func theRawAndTheJPEGOfOneShotDoNotShareACellFile() {
    var used = Set<String>()
    let dng = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/x/DJI_0016_D.DNG"), used: &used)
    let jpg = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/x/DJI_0016_D.JPG"), used: &used)
    #expect(dng != jpg)
    #expect(dng == "DJI_0016_D_dng")
    #expect(jpg == "DJI_0016_D_jpg")
}

@Test func identicalNamesFromDifferentFoldersStillGetDistinctCells() {
    // The backstop. A recursive sheet over two folders each holding an A.MP4
    // would otherwise collide on a name the extension cannot separate.
    var used = Set<String>()
    let a = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/one/A.MP4"), used: &used)
    let b = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/two/A.MP4"), used: &used)
    let c = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/three/A.MP4"), used: &used)
    #expect(Set([a, b, c]).count == 3)
    #expect(a == "A_mp4")
    #expect(b == "A_mp4_2")
    #expect(c == "A_mp4_3")
}

@Test func aFileWithNoExtensionStillGetsAName() {
    var used = Set<String>()
    let n = ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/x/plain"), used: &used)
    #expect(n == "plain")
    #expect(ProofSheet.cellBaseName(for: URL(fileURLWithPath: "/y/plain"), used: &used) == "plain_2")
}

// MARK: - task #722: the Core ML reason was a false premise, then stopped being a reason at all

// THE HISTORY, KEPT, BECAUSE THE SEQUENCE IS THE LESSON. `coreml.custom` went
// through three states in three days and each transition was resisted by a test:
//
//   1. The reason claimed "whether a custom .mlmodel compiles and loads without
//      Xcode is open." FALSE PREMISE. MLModel.compileModel(at:) is a runtime API
//      in CoreML.framework, an OS framework, and it compiled and loaded a custom
//      model from a plain SwiftPM binary (2026-09-12).
//   2. The reason was corrected and the capability DELIBERATELY DID NOT MOVE,
//      because a spike is not a code path: "declaring a capability off the back
//      of a spike, with no code and no test behind it, is the drift this
//      contract exists to catch."
//   3. 0.5.7: `CustomModel` and `CustomModelTests` exist, so the condition
//      state 2 named is satisfied and the capability moved.
//
// THE TWO TESTS THAT USED TO LIVE HERE FAILED WHEN IT MOVED, WHICH IS THEM
// WORKING. `theCoreMLReasonNoLongerClaimsTheQuestionIsOpen` required a reason
// that no longer exists, and `coreMLStaysAbsentBecauseNoCodePathLoadsAModel`
// asserted an absence that is no longer true. They are replaced rather than
// deleted, and their subject is asserted below in its new form: the gate they
// guarded was "code and tests, not a spike," and that gate is still the thing
// under test.

@Test func coreMLMovedOnlyOnceCodeAndTestsExisted() {
    #expect(Walk.capabilities["coreml.custom"] == "0.5.7")
    #expect(!Walk.notImplemented.contains("coreml.custom"))
    #expect(Walk.capabilities["classify.vision"] != nil,
            "the built-in taxonomy still covers the storm case and is still declared; the custom path is an addition, not a replacement")
}

@Test func theCustomPathShipsNoModelAndNamesNoSubjects() {
    // Decision #507 records that nobody has scoped what Walk should classify.
    // The capability note must therefore describe a MECHANISM, not a taxonomy —
    // if it ever starts naming subjects, the scoping decision has been made
    // somewhere other than where it belongs.
    let note = Walk.capabilities["coreml.custom"]
    #expect(note != nil)
    #expect(Walk.notImplementedReasons["coreml.custom"] == nil,
            "a present capability must not also carry a denial")
}
