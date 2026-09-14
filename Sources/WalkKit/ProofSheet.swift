import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// A TIME-SAMPLED proof sheet over a folder of mixed media: every still is one
/// cell, every clip is a strip of evenly-spaced frames across its whole
/// duration, and the whole thing is emitted as files plus one `manifest.json`.
///
/// WHAT THIS IS NOT, AND THE DISTINCTION IS THE WHOLE POINT.
/// `app.proofSheet` (0.3.0) shows DETECTED CANDIDATES — the frames the
/// luminance detector flagged. That answers "where did the light change in this
/// clip". It cannot answer "what is in this clip", because a clip whose light
/// never changes produces no candidates at all and therefore no picture: on the
/// operator's own GoPro folder two of eight clips returned nothing, which is an
/// honest answer to the detector's question and a blank row on a proof sheet.
/// MEASURED 2026-09-12: answering "what is worth keeping in this folder" meant
/// leaving Walk entirely and hand-writing ffmpeg tile commands, because a
/// time-sampled sheet of a whole clip did not exist here. This is that sheet,
/// and it is declared under its own capability name (`sheet.timeSampled`)
/// rather than by widening `app.proofSheet` until it covers both — the
/// `ingest.dump` / `ingest.folderScan` precedent from #507.
///
/// IT DISPLAYS AND MEASURES. IT DOES NOT JUDGE. No band, no rank, no score, no
/// keep/pitch. #513 puts the verdict in the criteria file and #499 puts the
/// judgment in it; a sheet that quietly ordered cells by "interest" would be
/// `ingest.dump`, which is still absent and still says so.
///
/// WALK EMITS DATA, NOT A PAGE. There is no HTML, no CSS and no styling below
/// this line, deliberately: the viewer is a separate artifact built against
/// `manifest.json`, and a renderer compiled into the engine would be a second
/// place for the measurements to drift from how they are shown.
public enum ProofSheet {

    // MARK: - Options

    public struct Options: Sendable {
        /// Frames sampled per clip, evenly spaced across the WHOLE duration.
        ///
        /// Even spacing rather than detection is the point of this sheet: the
        /// operator is looking at the arc of a clip, and a sample chosen by a
        /// brightness detector is a sample chosen by one property of one kind of
        /// event.
        public var framesPerClip: Int
        /// Longest edge of a sharp cell image, in pixels.
        public var cellWidth: CGFloat
        /// Longest edge of the inline placeholder. Kept tiny on purpose: it is
        /// carried inside the manifest as a base64 data URI, so its size is
        /// multiplied by every cell in the sheet.
        public var placeholderWidth: CGFloat
        public var jpegQuality: Double
        public var placeholderQuality: Double
        public var outputDirectory: URL
        public var recursive: Bool
        public var maximumItems: Int?
        /// Skip the placeholder pass. The sheet is then emitted in one pass and
        /// the manifest carries no placeholders — faster overall, and it loses
        /// the progressive fill that is the reason this exists.
        public var placeholders: Bool

        public init(outputDirectory: URL,
                    framesPerClip: Int = 12,
                    cellWidth: CGFloat = 900,
                    placeholderWidth: CGFloat = 20,
                    jpegQuality: Double = 0.72,
                    placeholderQuality: Double = 0.4,
                    recursive: Bool = false,
                    maximumItems: Int? = nil,
                    placeholders: Bool = true) {
            self.outputDirectory = outputDirectory
            self.framesPerClip = framesPerClip
            self.cellWidth = cellWidth
            self.placeholderWidth = placeholderWidth
            self.jpegQuality = jpegQuality
            self.placeholderQuality = placeholderQuality
            self.recursive = recursive
            self.maximumItems = maximumItems
            self.placeholders = placeholders
        }

        /// Where a sheet goes when the caller does not name a directory. A cache
        /// directory and not a temp one, for the same reason `ClipScan` uses
        /// one: the viewer reads these files back by path after the call
        /// returns, and a temp sweep between the answer and the read looks
        /// exactly like a broken sheet.
        public static func defaultDirectory(name: String = "sheet") -> URL {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent("Walk/sheets/\(name)", isDirectory: true)
        }
    }

    // MARK: - What comes back

    public struct Cell: Sendable {
        /// Position in this item's strip, 0-based. A still has exactly one.
        public let index: Int
        /// Video frame index. `nil` for a still, which has no frame.
        public let frame: Int?
        public let timecode: String?
        public let seconds: Double?
        /// Where the sharp image is written. The file may not exist yet — that
        /// is the point of `ready`, and of the manifest being rewritten.
        public let file: URL
        /// Tiny tone-mapped JPEG as a `data:` URI, or nil before the
        /// placeholder pass reaches this cell.
        public var placeholder: String?
        /// True once the sharp file is on disk.
        public var ready: Bool
        public var decodeMilliseconds: Double?
        /// Set when this one cell could not be produced. One bad frame does not
        /// void the strip.
        public var error: String?
    }

    public struct Item: Sendable {
        public let url: URL
        public let kind: MediaFinder.Kind
        public let bytes: Int64
        public let width: Int
        public let height: Int
        /// Clips only.
        public let fps: Double?
        public let seconds: Double?
        public let frameCount: Int?
        public let codec: String?
        public let colorPrimaries: String?
        public let transferFunction: String?
        public let yCbCrMatrix: String?
        public let isHLGBT2020: Bool
        public let dataRateMbps: Double?
        /// Stills only — the ICC profile the file declares.
        public let colorProfile: String?
        /// Which display transform was applied to this item's cells, named so a
        /// flat-looking cell can be told from an untransformed one.
        public let toneMap: String
        public let telemetry: DroneTelemetry?
        public let shutter: DroneTelemetry.ShutterRule?
        public var cells: [Cell]
        public let error: String?

        public var megapixels: Double { Double(width * height) / 1e6 }
    }

    public struct Result: Sendable {
        public let directory: URL
        public let manifest: URL
        public let found: MediaFinder.Found
        public let items: [Item]
        public let metadataSeconds: Double
        public let placeholderSeconds: Double
        public let sharpSeconds: Double
        public let totalSeconds: Double

        public var cellCount: Int { items.reduce(0) { $0 + $1.cells.count } }
        public var readyCells: Int { items.reduce(0) { $0 + $1.cells.filter(\.ready).count } }
        public var failedCells: Int { items.reduce(0) { $0 + $1.cells.filter { $0.error != nil }.count } }

        public var verdict: String {
            if items.isEmpty { return found.verdict }
            var s = "\(items.count) item\(items.count == 1 ? "" : "s"), \(cellCount) cell\(cellCount == 1 ? "" : "s"), \(readyCells) rendered"
            if failedCells > 0 { s += ", \(failedCells) could not be decoded" }
            let unreadable = items.filter { $0.error != nil }.count
            if unreadable > 0 { s += "; \(unreadable) item\(unreadable == 1 ? "" : "s") could not be read at all" }
            return s
        }
    }

    /// Progress, so a front door can say what it is doing during a pass that
    /// takes tens of seconds on real material.
    public enum Progress: Sendable {
        case enumerated(items: Int, cells: Int)
        case manifestWritten(URL)
        case placeholder(item: Int, cell: Int, of: Int)
        case sharp(item: Int, cell: Int, of: Int)
        case itemFailed(URL, String)
    }

    // MARK: - Rendering

    /// A `CIContext` that can cross a suspension point.
    ///
    /// `CIContext` is not `Sendable`, and holding one across `await` in an async
    /// function is a compile error under Swift 6 — the good kind, since most
    /// types are genuinely unsafe there. This one is not: Apple documents
    /// CIContext as thread-safe and states that multiple threads may use the
    /// same instance. The `@unchecked` states that invariant rather than hiding
    /// the diagnostic, the same way `HLGGrade.kernel` carries
    /// `nonisolated(unsafe)` with its reason written down.
    ///
    /// It exists at all because the context is worth reusing: MEASURED
    /// 2026-09-12 on `DJI_20260913024928_0001_D.MP4`, twelve evenly-spaced 4K
    /// frames cost 0.104 s/frame building a fresh Metal context per cell and
    /// 0.079 s/frame through one shared context — 24% of the render, on a job
    /// whose whole purpose is not making the operator wait.
    final class Renderer: @unchecked Sendable {
        let context: CIContext
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        init?() {
            guard let c = Frame.makeDisplayContext() else { return nil }
            self.context = c
        }

        /// Tone map a LINEAR-LIGHT image and encode it as a JPEG.
        func jpeg(fromLinear image: CIImage, maxWidth: CGFloat, quality: Double) -> Data? {
            let scale = maxWidth > 0 && image.extent.width > 0
                ? min(1.0, maxWidth / image.extent.width) : 1.0
            var out = HLGGrade.tonemapForDisplay(image)
            if scale < 1.0 { out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            guard let cg = context.createCGImage(out, from: out.extent,
                                                 format: .RGBA8, colorSpace: sRGB) else { return nil }
            return ProofSheet.encodeJPEG(cg, quality: quality)
        }

        func jpeg(from cg: CGImage, maxWidth: CGFloat, quality: Double) -> Data? {
            guard maxWidth > 0, CGFloat(cg.width) > maxWidth else {
                return ProofSheet.encodeJPEG(cg, quality: quality)
            }
            let scale = maxWidth / CGFloat(cg.width)
            let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let small = context.createCGImage(image, from: image.extent,
                                                    format: .RGBA8, colorSpace: sRGB) else { return nil }
            return ProofSheet.encodeJPEG(small, quality: quality)
        }
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func dataURI(_ jpeg: Data) -> String {
        "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    // MARK: - Sampling

    /// The frame indices sampled from a clip: `count` points spaced evenly
    /// across the whole clip, each at the CENTER of its slice.
    ///
    /// Centered rather than from zero, and that is not cosmetic. Sampling at
    /// `i * total / count` puts the first sample on frame 0 — which on drone
    /// footage is the aircraft still settling, the gimbal still levelling, and
    /// frequently a black or half-exposed frame. It also never reaches the end
    /// of the clip. Centering each sample in its own slice gives twelve frames
    /// that each represent a twelfth of the clip, and none of them is frame 0.
    public static func sampleIndices(frameCount: Int, count: Int) -> [Int] {
        guard frameCount > 0, count > 0 else { return [] }
        guard frameCount > count else { return Array(0..<frameCount) }
        return (0..<count).map {
            min(frameCount - 1, Int((Double($0) + 0.5) / Double(count) * Double(frameCount)))
        }
    }

    // MARK: - Cell file names

    /// A base name for one item's cells that no other item in this sheet can
    /// also produce.
    ///
    /// THE DEFECT THIS EXISTS FOR, MEASURED 2026-09-12 ON THE FIRST REAL RUN.
    /// The obvious name is the file's stem, and on the operator's own card
    /// `DJI_20260517021954_0016_D.DNG` and `DJI_20260517021954_0016_D.JPG` are
    /// the raw and the JPEG of one shot — the same stem. Both cells were
    /// written to `DJI_20260517021954_0016_D_c00.jpg`, the second overwrote the
    /// first, and BOTH REPORTED `ready: true`. The manifest said 99 cells
    /// rendered and 98 files existed. Nothing failed, nothing logged, and the
    /// sheet would simply have shown the DNG twice under two names.
    ///
    /// That is absence indistinguishable from success, in an artifact whose
    /// whole job is showing the operator what is really on his card. The
    /// extension goes in the name because it is the thing that actually differs;
    /// the `used` set is the backstop for any collision the extension does not
    /// resolve, so the invariant is enforced rather than argued for.
    static func cellBaseName(for url: URL, used: inout Set<String>) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        var candidate = ext.isEmpty ? stem : "\(stem)_\(ext)"
        var n = 2
        while !used.insert(candidate).inserted {
            candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(ext)_\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - The run

    /// Build a sheet over everything given.
    ///
    /// THREE PASSES, AND THE ORDER IS THE FEATURE.
    ///
    ///   1. Enumerate and read metadata. Instant — container timing, dimensions
    ///      and the `.SRT` sidecar, no pixels. `manifest.json` is written here,
    ///      complete, with every item and every cell slot present and
    ///      `ready: false`. A viewer can lay the whole sheet out from this.
    ///   2. Placeholders. One tiny tone-mapped JPEG per cell, carried inline in
    ///      the manifest as a data URI. MEASURED at 0.041 s/frame against
    ///      0.079 s/frame for a sharp cell, because it asks the decoder for the
    ///      nearest sync sample instead of an exact frame.
    ///   3. Sharp cells, written to disk one at a time. The manifest is rewritten
    ///      after each item so a viewer polling it sees the sheet resolve.
    ///
    /// Every manifest write is ATOMIC. A viewer polling the file while it is
    /// being rewritten would otherwise read half a document and parse it as a
    /// corrupt sheet.
    public static func run(_ inputs: [URL],
                           options: Options,
                           progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        func since(_ t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9 }

        let fm = FileManager.default
        try fm.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let cellsDirectory = options.outputDirectory.appendingPathComponent("cells", isDirectory: true)
        try fm.createDirectory(at: cellsDirectory, withIntermediateDirectories: true)
        let manifestURL = options.outputDirectory.appendingPathComponent("manifest.json")

        guard let renderer = Renderer() else { throw WalkVideoError.noMetalDevice }

        var findOptions = ClipFinder.Options()
        findOptions.recursive = options.recursive
        findOptions.maximumClips = options.maximumItems
        let found = MediaFinder.find(inputs, options: findOptions)

        // ---- Pass 1: metadata only -----------------------------------------
        var items = [Item]()
        var usedNames = Set<String>()
        for media in found.items {
            let stem = cellBaseName(for: media.url, used: &usedNames)
            switch media.kind {
            case .clip:
                do {
                    let reader = try await VideoReader(url: media.url)
                    let info = reader.info
                    let indices = sampleIndices(frameCount: info.estimatedFrameCount,
                                                count: options.framesPerClip)
                    let telemetry = DroneTelemetry.sidecar(for: media.url).flatMap(DroneTelemetry.read)
                    let cells = indices.enumerated().map { n, frame in
                        Cell(index: n, frame: frame,
                             timecode: reader.timecode(ofFrame: frame),
                             seconds: CMTimeGetSeconds(reader.time(ofFrame: frame)),
                             file: cellsDirectory.appendingPathComponent(
                                String(format: "%@_c%02d_f%06d.jpg", stem, n, frame)),
                             placeholder: nil, ready: false,
                             decodeMilliseconds: nil, error: nil)
                    }
                    items.append(Item(
                        url: media.url, kind: .clip, bytes: media.bytes,
                        width: info.width, height: info.height,
                        fps: info.fps, seconds: info.seconds,
                        frameCount: info.estimatedFrameCount, codec: info.codec,
                        colorPrimaries: info.colorPrimaries,
                        transferFunction: info.transferFunction,
                        yCbCrMatrix: info.yCbCrMatrix,
                        isHLGBT2020: info.isHLGBT2020,
                        dataRateMbps: info.estimatedDataRateMbps,
                        colorProfile: nil,
                        toneMap: clipToneMapNote(info),
                        telemetry: telemetry,
                        shutter: telemetry?.shutterRule(fps: info.fps),
                        cells: cells, error: nil))
                } catch {
                    progress?(.itemFailed(media.url, "\(error)"))
                    items.append(Item(url: media.url, kind: .clip, bytes: media.bytes,
                                      width: 0, height: 0, fps: nil, seconds: nil,
                                      frameCount: nil, codec: nil, colorPrimaries: nil,
                                      transferFunction: nil, yCbCrMatrix: nil,
                                      isHLGBT2020: false, dataRateMbps: nil,
                                      colorProfile: nil, toneMap: "not reached — the clip could not be opened",
                                      telemetry: nil, shutter: nil, cells: [],
                                      error: "\(error)"))
                }
            case .still:
                let props = stillProperties(media.url)
                let cell = Cell(index: 0, frame: nil, timecode: nil, seconds: nil,
                                file: cellsDirectory.appendingPathComponent("\(stem)_c00.jpg"),
                                placeholder: nil, ready: false,
                                decodeMilliseconds: nil, error: nil)
                items.append(Item(
                    url: media.url, kind: .still, bytes: media.bytes,
                    width: props.width, height: props.height,
                    fps: nil, seconds: nil, frameCount: nil,
                    codec: props.type, colorPrimaries: nil,
                    transferFunction: nil, yCbCrMatrix: nil,
                    isHLGBT2020: false, dataRateMbps: nil,
                    colorProfile: props.profile,
                    toneMap: stillToneMapNote(props.profile),
                    telemetry: nil, shutter: nil,
                    cells: [cell],
                    error: props.width > 0 ? nil : "no readable image properties"))
            }
        }
        let metadataSeconds = since(t0)
        progress?(.enumerated(items: items.count,
                              cells: items.reduce(0) { $0 + $1.cells.count }))
        try writeManifest(items: items, found: found, inputs: inputs, options: options,
                          to: manifestURL, status: .sampling,
                          metadataSeconds: metadataSeconds,
                          placeholderSeconds: 0, sharpSeconds: 0)
        progress?(.manifestWritten(manifestURL))

        // ---- Pass 2: placeholders ------------------------------------------
        let tPlaceholder = DispatchTime.now().uptimeNanoseconds
        if options.placeholders {
            for (i, item) in items.enumerated() where item.error == nil {
                switch item.kind {
                case .clip:
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 128, height: 128)
                    // NEAREST SYNC SAMPLE, and this is the whole reason the
                    // placeholder pass is fast. An exact frame means decoding
                    // forward from the preceding keyframe; infinite tolerance
                    // means the keyframe itself. MEASURED: 0.041 s/frame here
                    // against 0.079 s/frame for the exact cell.
                    //
                    // It is therefore NOT THE SAME FRAME as the sharp cell that
                    // replaces it, and the manifest says so rather than leaving
                    // a reader to assume otherwise. At 20 pixels wide, blurred,
                    // that is a distinction without a visible difference — but
                    // an undocumented one is how thirteen verdicts landed on the
                    // wrong thirteen frames in #740.
                    generator.requestedTimeToleranceBefore = .positiveInfinity
                    generator.requestedTimeToleranceAfter = .positiveInfinity
                    for (n, cell) in item.cells.enumerated() {
                        // THE CELL'S OWN `seconds`, which pass 1 took from
                        // `VideoReader.time(ofFrame:)` and its exact rational
                        // frame duration. Recomputing it here as
                        // seconds / frameCount at timescale 600 DRIFTS: on
                        // DJI_20260913024928_0001_D.MP4 the rounded per-frame
                        // duration is 13/600 against a true 1001/48000, and by
                        // frame 10781 that is 233.6 s against a clip 224.8 s
                        // long — every late placeholder would have been the
                        // decoder clamping to the final keyframe, silently, and
                        // blurred to 20 pixels nobody would have seen it.
                        guard cell.frame != nil, let seconds = cell.seconds else { continue }
                        let time = CMTime(seconds: seconds, preferredTimescale: 48000)
                        if let cg = try? await generator.image(at: time).image,
                           // UNTAGGED, AND DELIBERATELY SO. The generator hands
                           // back LINEAR LIGHT in an untagged buffer — the same
                           // state a decoded CVPixelBuffer arrives in — so what
                           // is still owed is the Hable curve and nothing else.
                           // MEASURED 2026-09-12 against Walk's exact decode of
                           // the same keyframe (R52.5 G57.5 B62.0): untagged
                           // plus tone map gives R52.4 G58.1 B63.6; tagging it
                           // ITU-R 2100 HLG first gives R34.7 G39.1 B43.9, a
                           // second decode of something already decoded, which
                           // is the same units error as the system-gamma-1.2
                           // defect. The transform is not guessed at here, it is
                           // the one that reproduced the reference.
                           let jpeg = renderer.jpeg(fromLinear: CIImage(cgImage: cg),
                                                    maxWidth: options.placeholderWidth,
                                                    quality: options.placeholderQuality) {
                            items[i].cells[n].placeholder = dataURI(jpeg)
                        }
                        progress?(.placeholder(item: i, cell: n, of: item.cells.count))
                    }
                case .still:
                    if let cg = stillThumbnail(item.url, maxPixel: 128),
                       let jpeg = renderer.jpeg(from: cg, maxWidth: options.placeholderWidth,
                                                quality: options.placeholderQuality) {
                        items[i].cells[0].placeholder = dataURI(jpeg)
                    }
                    progress?(.placeholder(item: i, cell: 0, of: 1))
                }
                try writeManifest(items: items, found: found, inputs: inputs, options: options,
                                  to: manifestURL, status: .sampling,
                                  metadataSeconds: metadataSeconds,
                                  placeholderSeconds: since(tPlaceholder), sharpSeconds: 0)
            }
        }
        let placeholderSeconds = since(tPlaceholder)
        progress?(.manifestWritten(manifestURL))

        // ---- Pass 3: sharp cells -------------------------------------------
        let tSharp = DispatchTime.now().uptimeNanoseconds
        for (i, item) in items.enumerated() where item.error == nil {
            switch item.kind {
            case .clip:
                do {
                    let reader = try await VideoReader(url: item.url)
                    for (n, cell) in item.cells.enumerated() {
                        guard let index = cell.frame else { continue }
                        let t = DispatchTime.now().uptimeNanoseconds
                        do {
                            let frame = try await reader.frame(at: index)
                            guard let cg = frame.makeDisplayImage(maxWidth: options.cellWidth,
                                                                  context: renderer.context),
                                  let jpeg = encodeJPEG(cg, quality: options.jpegQuality) else {
                                items[i].cells[n].error = "the frame decoded but would not render"
                                continue
                            }
                            try jpeg.write(to: cell.file, options: .atomic)
                            items[i].cells[n].ready = true
                            items[i].cells[n].decodeMilliseconds = since(t) * 1000
                        } catch {
                            // ONE BAD FRAME IS NOT A BAD CLIP. A strip missing
                            // its ninth cell is still eleven twelfths of an
                            // answer, and the cell says why it is empty.
                            items[i].cells[n].error = "\(error)"
                        }
                        progress?(.sharp(item: i, cell: n, of: item.cells.count))
                    }
                } catch {
                    progress?(.itemFailed(item.url, "\(error)"))
                }
            case .still:
                let t = DispatchTime.now().uptimeNanoseconds
                if let cg = stillThumbnail(item.url, maxPixel: Int(options.cellWidth)),
                   let jpeg = encodeJPEG(cg, quality: options.jpegQuality),
                   (try? jpeg.write(to: item.cells[0].file, options: .atomic)) != nil {
                    items[i].cells[0].ready = true
                    items[i].cells[0].decodeMilliseconds = since(t) * 1000
                } else {
                    items[i].cells[0].error = "the still could not be decoded to a thumbnail"
                }
                progress?(.sharp(item: i, cell: 0, of: 1))
            }
            try writeManifest(items: items, found: found, inputs: inputs, options: options,
                              to: manifestURL, status: .sampling,
                              metadataSeconds: metadataSeconds,
                              placeholderSeconds: placeholderSeconds,
                              sharpSeconds: since(tSharp))
        }
        let sharpSeconds = since(tSharp)

        try writeManifest(items: items, found: found, inputs: inputs, options: options,
                          to: manifestURL, status: .complete,
                          metadataSeconds: metadataSeconds,
                          placeholderSeconds: placeholderSeconds,
                          sharpSeconds: sharpSeconds)
        progress?(.manifestWritten(manifestURL))

        return Result(directory: options.outputDirectory, manifest: manifestURL,
                      found: found, items: items,
                      metadataSeconds: metadataSeconds,
                      placeholderSeconds: placeholderSeconds,
                      sharpSeconds: sharpSeconds,
                      totalSeconds: since(t0))
    }

    // MARK: - Stills

    struct StillProperties {
        var width = 0, height = 0
        var profile: String? = nil
        var type: String? = nil
    }

    static func stillProperties(_ url: URL) -> StillProperties {
        var p = StillProperties()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return p }
        p.type = (CGImageSourceGetType(src) as String?)
        guard let d = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return p }
        p.width = (d[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        p.height = (d[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        p.profile = d[kCGImagePropertyProfileName] as? String
        return p
    }

    /// A correctly oriented, color-managed thumbnail of a still.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than a full decode, and the
    /// difference is not small: the operator's own DJI JPG is 12000x6000 and
    /// 36.7 MB, and a proof-sheet cell is 900 pixels wide. ImageIO decodes at
    /// the size asked for. `FromImageAlways` is set because an embedded EXIF
    /// thumbnail is typically 160 pixels and would be a blurred cell that looked
    /// like a bug; `WithTransform` applies the EXIF orientation, without which a
    /// portrait frame lands on its side.
    static func stillThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    // MARK: - Naming the transform

    static func clipToneMapNote(_ info: VideoInfo) -> String {
        let base = "decoded to linear light in \(VideoReader.workingColorSpaceName) (pinned), Hable filmic curve, encoded sRGB"
        if info.isHLGBT2020 {
            return base + ". SOURCE IS HLG BT.2020: the inverse OETF and the OOTF are applied by the decoder, so Walk applies the curve and nothing else — running the inverse OETF again here would be a second decode of something already decoded. The BT.2390 SDR system gamma for a 100 cd/m2 display is 0.78, not the widely-quoted 1.2, which is the 1000 cd/m2 HDR value; see hlg.systemGamma in walk_contract."
        }
        return base + ". Source does not declare HLG BT.2020 (primaries \(info.colorPrimaries ?? "unstated"), transfer \(info.transferFunction ?? "unstated")); the same filmic curve is applied, which is what every other picture Walk writes does. Stated because applying a highlight-rolloff curve to already-display-referred footage darkens it slightly, and a cell that looks flat should be readable as a transform rather than as the footage."
    }

    static func stillToneMapNote(_ profile: String?) -> String {
        "ImageIO thumbnail, color-managed from the file's own profile (\(profile ?? "unstated")) to sRGB. NO filmic curve and no HLG transform: these files are display-referred already, and the clip path's curve would darken them. A still and a clip cell in this sheet are therefore NOT the same transform, which is why each item names its own."
    }

    // MARK: - The manifest

    public enum Status: String, Sendable { case sampling, complete }

    /// Serialize and write, ATOMICALLY.
    ///
    /// The manifest is rewritten after every item so that a viewer polling it
    /// watches the sheet resolve. A plain write would let that viewer read a
    /// half-written document and report a corrupt sheet — a failure that would
    /// appear at random, on big folders only, and look like a parser bug.
    static func writeManifest(items: [Item], found: MediaFinder.Found,
                              inputs: [URL], options: Options,
                              to url: URL, status: Status,
                              metadataSeconds: Double,
                              placeholderSeconds: Double,
                              sharpSeconds: Double) throws {
        let payload = manifest(items: items, found: found, inputs: inputs, options: options,
                               status: status, metadataSeconds: metadataSeconds,
                               placeholderSeconds: placeholderSeconds, sharpSeconds: sharpSeconds)
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// PUBLIC so the manifest can be built and asserted without writing a file.
    public static func manifest(items: [Item], found: MediaFinder.Found,
                                inputs: [URL], options: Options,
                                status: Status = .complete,
                                metadataSeconds: Double = 0,
                                placeholderSeconds: Double = 0,
                                sharpSeconds: Double = 0) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return [
            "walk": Walk.version,
            "manifestVersion": 1,
            "generated": iso.string(from: Date()),
            // THE FIELD A VIEWER POLLS. "sampling" means more cells are coming;
            // "complete" means every cell that will ever exist is described.
            "status": status.rawValue,
            "directory": options.outputDirectory.path,
            "asked": inputs.map(\.path),
            "options": [
                "framesPerClip": options.framesPerClip,
                "cellWidth": Int(options.cellWidth),
                "placeholderWidth": Int(options.placeholderWidth),
                "jpegQuality": options.jpegQuality,
                "recursive": options.recursive,
                "placeholders": options.placeholders,
            ],
            "search": [
                "foldersSearched": found.directoriesSearched.map(\.path),
                "itemsFound": found.items.count,
                "clipsFound": found.clips.count,
                "stillsFound": found.stills.count,
                "nothingToSheet": found.foundNothing,
                "verdict": found.verdict,
                "videoExtensions": ClipFinder.videoExtensions.sorted(),
                "stillExtensions": MediaFinder.stillExtensions.sorted(),
                "skipped": found.skipped.map { ["name": $0.url.lastPathComponent, "reason": $0.reason] },
            ],
            "sampling": [
                "rule": "\(options.framesPerClip) frames per clip, evenly spaced across the whole duration, each centered in its own slice — so no sample is frame 0, where a drone is still settling, and the last slice is reached.",
                "note": "These are TIME SAMPLES, not detected events. Nothing here was chosen because it was bright, moving or interesting; see walk_scan for the detector and ingest.dump in walk_contract for why ranking a mixed folder is still absent.",
            ],
            "placeholderContract": [
                "form": "base64 JPEG data URI on every cell, longest edge \(Int(options.placeholderWidth)) px",
                "intendedUse": "draw it immediately, blurred, and replace it with `file` once that path exists",
                "provenance": "NEAREST SYNC SAMPLE, not the frame the sharp cell shows. Asking the decoder for an exact frame means decoding forward from the preceding keyframe; asking with infinite tolerance returns the keyframe itself, measured at 0.041 s against 0.079 s per frame. At this size, blurred, the difference is not visible — but it is a different frame and is named rather than assumed.",
                "transform": "the same tone map as the sharp cell",
            ],
            // #513 AND #499, STATED IN THE ARTIFACT ITSELF so a viewer cannot
            // add a verdict Walk did not render.
            "judgment": [
                "rendered": false,
                "note": "THIS SHEET DISPLAYS AND MEASURES. It does not band, rank, score or sort by interest, and no cell carries a keep/pitch verdict. Walk's coaching verdict is rendered from a criteria file by walk_scan and walk_scan_folder (see coach.available there); it is a separate call and it is not part of a proof sheet. A viewer that adds a verdict of its own invention is not reporting Walk.",
                "shutterNote": "An item's `shutter` block compares the clip's own measured shutter distribution against the 180-degree convention, 1/(2 x fps). That is a MEASUREMENT against a named standard and it is not a judgment: a fast shutter is a deliberate choice and Walk does not rule on whether it was the right one.",
            ],
            "timings": [
                "metadataSeconds": metadataSeconds,
                "placeholderSeconds": placeholderSeconds,
                "sharpSeconds": sharpSeconds,
            ],
            "items": items.map(itemDictionary),
        ]
    }

    static func itemDictionary(_ item: Item) -> [String: Any] {
        var d: [String: Any] = [
            "path": item.url.path,
            "name": item.url.lastPathComponent,
            "kind": item.kind.rawValue,
            "bytes": item.bytes,
            "width": item.width,
            "height": item.height,
            "megapixels": item.megapixels,
            "toneMap": item.toneMap,
            "cells": item.cells.map(cellDictionary),
        ]
        if let v = item.fps { d["fps"] = v }
        if let v = item.seconds { d["seconds"] = v }
        if let v = item.frameCount { d["frameCount"] = v }
        if let v = item.codec { d["codec"] = v }
        if let v = item.colorPrimaries { d["colorPrimaries"] = v }
        if let v = item.transferFunction { d["transferFunction"] = v }
        if let v = item.yCbCrMatrix { d["yCbCrMatrix"] = v }
        if let v = item.dataRateMbps { d["dataRateMbps"] = v }
        if let v = item.colorProfile { d["colorProfile"] = v }
        if item.kind == .clip { d["isHLGBT2020"] = item.isHLGBT2020 }
        if let v = item.error { d["error"] = v }
        if let t = item.telemetry { d["telemetry"] = telemetryDictionary(t) }
        if let s = item.shutter { d["shutter"] = shutterDictionary(s) }
        return d
    }

    static func cellDictionary(_ c: Cell) -> [String: Any] {
        var d: [String: Any] = [
            "index": c.index,
            "file": c.file.path,
            "ready": c.ready,
        ]
        if let v = c.frame { d["frame"] = v }
        if let v = c.timecode { d["timecode"] = v }
        if let v = c.seconds { d["seconds"] = v }
        if let v = c.placeholder { d["placeholder"] = v }
        if let v = c.decodeMilliseconds { d["decodeMilliseconds"] = v }
        if let v = c.error { d["error"] = v }
        return d
    }

    /// How many distinct values of a field are serialized before the tail is
    /// summarized. A clip can hold hundreds; the manifest is read by a browser.
    static let distinctCap = 12

    static func distributionDictionary(_ d: DroneTelemetry.Distribution) -> [String: Any] {
        let head = d.distinct.prefix(distinctCap)
        var out: [String: Any] = [
            "samples": d.samples,
            "min": d.minimum,
            "max": d.maximum,
            "median": d.median,
            "mode": d.mode,
            "modeShare": d.modeShare,
            "constant": d.constant,
            "distinctCount": d.distinct.count,
            "distinct": head.map { ["value": $0.value, "count": $0.count] },
            // FRAME 1, CARRIED AND NOT USED. The whole reason this type reads a
            // distribution is that the opening sample describes an aircraft that
            // is still settling.
            "firstSample": d.first,
            "firstSampleNote": "the value at the FIRST sample in the file, reported for comparison and never used as the reading: the aircraft is still settling at the start of a clip, which is why every field here is summarized over the whole file.",
        ]
        if d.distinct.count > distinctCap {
            out["distinctTrimmed"] = true
            out["distinctShown"] = distinctCap
        }
        if let stops = d.firstIsStopsFromMedian { out["firstSampleStopsFromMedian"] = stops }
        return out
    }

    static func telemetryDictionary(_ t: DroneTelemetry) -> [String: Any] {
        var d: [String: Any] = [
            "source": t.source.lastPathComponent,
            "samples": t.sampleCount,
            "modeledKeys": DroneTelemetry.modeledKeys,
            "unmodeledKeys": t.unmodeledKeys,
        ]
        if let v = t.iso { d["iso"] = distributionDictionary(v) }
        if let v = t.shutterDenominator {
            var s = distributionDictionary(v)
            s["unit"] = "denominator — 240 means a shutter of 1/240 s"
            d["shutterDenominator"] = s
        }
        if let v = t.fNumber { d["fNumber"] = distributionDictionary(v) }
        if let v = t.exposureValue { d["exposureValue"] = distributionDictionary(v) }
        if let v = t.focalLength { d["focalLength"] = distributionDictionary(v) }
        if let v = t.relativeAltitude { d["relativeAltitudeMeters"] = distributionDictionary(v) }
        if let v = t.colorMode { d["colorMode"] = v }
        return d
    }

    static func shutterDictionary(_ s: DroneTelemetry.ShutterRule) -> [String: Any] {
        [
            "rule": "180-degree shutter: 1/(2 x fps)",
            "fps": s.fps,
            "oneEightyDenominator": s.oneEightyDenominator,
            "medianDenominator": s.medianDenominator,
            "stopsFromOneEighty": s.stopsFromOneEighty,
            "toleranceStops": s.toleranceStops,
            "withinTolerance": s.withinTolerance,
            "shareWithinTolerance": s.shareWithinTolerance,
            "impliedShutterAngle": s.impliedShutterAngle,
            "note": s.note,
            "isAVerdict": false,
        ]
    }
}
