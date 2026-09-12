import Foundation
import WalkKit

// THIS FILE IS A WRAPPER AND MUST STAY ONE.
//
// #507 makes the MCP surface the front door, not a second implementation. There
// is no image or video arithmetic below this line: every number comes out of
// WalkKit, where the tests are. If a future change wants a new measurement, it
// belongs in WalkKit and gets a capability entry and a test; adding it here
// would put engine code in a target the known-answer tests never touch, which is
// how the app came to walk folders the library did not declare.
//
// What this file legitimately owns: argument parsing, schemas, and turning
// WalkKit's types into JSON.

struct Tool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSON
    let readOnly: Bool
    let handler: @Sendable (JSON) async -> Outcome

    enum Outcome: Sendable {
        case ok(JSON, images: [InlineImage] = [])
        case failure(String)
    }

    struct InlineImage: Sendable {
        let base64: String
        let mimeType: String
    }

    var definition: JSON {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    func invoke(_ arguments: JSON) async -> JSON {
        switch await handler(arguments) {
        case .failure(let reason):
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string(reason)])]),
                "isError": .bool(true),
            ])
        case .ok(let structured, let images):
            // The spec says a tool returning structured content SHOULD also put
            // the serialized JSON in a text block, for clients that do not read
            // structuredContent. Both, therefore — same bytes, once each.
            let serialized = (try? structured.line()).flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"error\":\"result would not serialize\"}"
            var content: [JSON] = [.object(["type": .string("text"), "text": .string(serialized)])]
            for image in images {
                content.append(.object([
                    "type": .string("image"),
                    "data": .string(image.base64),
                    "mimeType": .string(image.mimeType),
                    "annotations": .object(["audience": .array([.string("user")]),
                                            "priority": .double(0.9)]),
                ]))
            }
            return .object([
                "content": .array(content),
                "structuredContent": structured,
                "isError": .bool(false),
            ])
        }
    }
}

// MARK: - schema helpers

private func schema(_ properties: [String: JSON], required: [String] = []) -> JSON {
    var o: [String: JSON] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
    return .object(o)
}

private func str(_ description: String) -> JSON {
    .object(["type": .string("string"), "description": .string(description)])
}
private func int(_ description: String, default d: Int? = nil) -> JSON {
    var o: [String: JSON] = ["type": .string("integer"), "description": .string(description)]
    if let d { o["default"] = .int(d) }
    return .object(o)
}
private func num(_ description: String, default d: Double? = nil) -> JSON {
    var o: [String: JSON] = ["type": .string("number"), "description": .string(description)]
    if let d { o["default"] = .double(d) }
    return .object(o)
}
private func bool(_ description: String, default d: Bool) -> JSON {
    .object(["type": .string("boolean"), "description": .string(description), "default": .bool(d)])
}

// MARK: - shared argument parsing

private struct ScanArgs {
    var options = ClipScan.Options.triage()
    var inlineImages = 0
    var maxCandidates = 200

    /// Hard ceiling on inline images regardless of what was asked for.
    ///
    /// MEASURED on this material and the reason the cap exists: a 640-pixel-wide
    /// display PNG off a 4K frame runs to a few hundred kilobytes, roughly a
    /// third larger again once base64-encoded. #507 records one GoPro clip
    /// producing 38 candidates. Inlining all of them would be tens of megabytes
    /// of images for one clip and the conversation would end before the operator
    /// saw a single frame. Paths are always returned; bytes are rationed.
    static let inlineImageCeiling = 6

    static func parse(_ a: JSON, defaultStride: Int) throws -> ScanArgs {
        var s = ScanArgs()
        var o = ClipScan.Options.triage()
        o.yPlaneStride = a["y_plane_stride"]?.intValue ?? defaultStride
        guard o.yPlaneStride >= 1 else { throw ToolError("y_plane_stride must be 1 or more") }
        o.classify = a["vision"]?.boolValue ?? true
        if let ids = a["identifiers"]?.arrayValue {
            let names = ids.compactMap(\.stringValue)
            guard !names.isEmpty else { throw ToolError("identifiers, if given, must be a non-empty array of strings") }
            o.identifiers = names
        }
        if let k = a["sigma"]?.doubleValue {
            guard k > 0 else { throw ToolError("sigma must be positive") }
            o.detector.sigmaMultiple = k
        }
        if let f = a["floor"]?.doubleValue {
            guard f >= 0 else { throw ToolError("floor must be zero or more (it is a fraction, so 0.01 is 1%)") }
            o.detector.minimumRelativeRise = f
        }
        let from = a["from_frame"]?.intValue
        let to = a["to_frame"]?.intValue
        if from != nil || to != nil {
            let lo = from ?? 0
            guard let hi = to, hi > lo else {
                throw ToolError("a frame range needs to_frame greater than from_frame (to_frame is exclusive)")
            }
            o.frames = lo..<hi
        }
        let wantThumbs = a["thumbnails"]?.boolValue ?? true
        if wantThumbs {
            o.thumbnailDirectory = a["thumbnail_dir"]?.stringValue
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? ClipScan.defaultThumbnailDirectory()
        } else {
            o.thumbnailDirectory = nil
        }
        if let w = a["thumbnail_width"]?.doubleValue {
            guard w >= 64, w <= 3840 else { throw ToolError("thumbnail_width must be between 64 and 3840") }
            o.thumbnailMaxWidth = w
        }
        s.options = o
        s.inlineImages = min(a["inline_images"]?.intValue ?? 0, inlineImageCeiling)
        s.maxCandidates = max(1, a["max_candidates"]?.intValue ?? 200)
        return s
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { self.description = d }
}

private let scanProperties: [String: JSON] = [
    "vision": bool("Ask the Vision classifier about each candidate. Off is faster and removes the only signal that finds a thin, distant bolt — luminance alone cannot tell one from sensor noise.", default: true),
    "identifiers": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Vision identifiers to report confidences for. Defaults to lightning, thunderstorm, storm. The taxonomy has 1303 entries; `walk identifiers <substring>` on the CLI lists them."),
    ]),
    "y_plane_stride": int("10-bit Y-plane sub-sampling. 1 is the known-answer path — it agrees with ffmpeg signalstats to three decimals, and costs about 95 fps against 361 fps at stride 4. Anything above 1 makes yMean approximate and it is labelled as such in the result.", default: 4),
    "from_frame": int("First frame to scan, inclusive. Omit to scan from the start."),
    "to_frame": int("Last frame to scan, EXCLUSIVE. Required if from_frame is given."),
    "sigma": num("Multiple of the clip's own robust (MAD-derived) sigma used for the statistical half of the threshold.", default: 12),
    "floor": num("Absolute floor on relative luminance rise, as a fraction. This constant is what makes 'nothing found' reachable, and also what would hide a real event fainter than it.", default: 0.01),
    "thumbnails": bool("Write one tone-mapped sRGB PNG per candidate and return its path, so the frame can be shown rather than described.", default: true),
    "thumbnail_dir": str("Where to write the PNGs. Defaults to a Walk folder under the user's Caches directory — a cache and not a temp directory, so the path is still valid when it is read back."),
    "thumbnail_width": num("Longest edge of the written PNG, in pixels.", default: 640),
    "inline_images": int("How many candidate frames to ALSO return as inline image content, highest lightning confidence first. Capped at 6. Zero by default: a 640px PNG is a few hundred KB and one clip can produce dozens of candidates, so paths are returned always and bytes only on request.", default: 0),
    "max_candidates": int("Ceiling on how many candidate rows come back. The counts and the verdict always reflect every candidate found, even when the rows are trimmed.", default: 200),
]

// MARK: - JSON for WalkKit's types

private func infoJSON(_ i: VideoInfo) -> JSON {
    .object([
        "path": .string(i.url.path),
        "name": .string(i.url.lastPathComponent),
        "width": .int(i.width), "height": .int(i.height),
        "megapixels": .double(i.megapixels),
        "codec": .string(i.codec),
        "bitDepth": .optional(i.bitDepth),
        "fps": .double(i.fps),
        "seconds": .double(i.seconds),
        "estimatedFrameCount": .int(i.estimatedFrameCount),
        "dataRateMbps": .double(i.estimatedDataRateMbps),
        "colorPrimaries": .optional(i.colorPrimaries),
        "transferFunction": .optional(i.transferFunction),
        "yCbCrMatrix": .optional(i.yCbCrMatrix),
        "isHLGBT2020": .bool(i.isHLGBT2020),
    ])
}

private func detectorJSON(_ d: EventDetector.Result) -> JSON {
    .object([
        "threshold": .double(d.threshold),
        "statisticalThreshold": .double(d.statisticalThreshold),
        "floorThreshold": .double(d.floorThreshold),
        "boundBy": .string(d.boundBy.rawValue),
        "robustSigma": .double(d.robustSigma),
        "medianRelativeRise": .double(d.medianRelativeRise),
        "framesConsidered": .int(d.framesConsidered),
        "candidatesBeforeMerge": .int(d.candidatesBeforeMerge),
        "scaleCollapsed": .bool(d.scaleCollapsed),
        "foundNothing": .bool(d.foundNothing),
        "note": .string("threshold = max(statistical, floor). boundBy says which half decided, so a reader can tell whether the answer came from the clip or from the constant. scaleCollapsed means more than half the frames sat exactly on their local median, so the clip supplied no measurable noise scale."),
    ])
}

private func candidateJSON(_ c: ClipScan.Candidate, exactY: Bool) -> JSON {
    var o: [String: JSON] = [
        "frame": .int(c.frame),
        "timecode": .string(c.timecode),
        "seconds": .double(c.time),
        "ciLuma": .double(c.ciLuma),
        "baseline": .double(c.baseline),
        "delta": .double(c.delta),
        "relativeRise": .double(c.relativeRise),
        "relativeRisePercent": .double(c.relativeRise * 100),
        "sigma": .double(c.sigma),
        "mergedFrames": .int(c.mergedFrames),
        "yMean": .optional(c.yMean),
        "yMeanExact": .bool(exactY),
        "yMax": .optional(c.yMax),
        "yClipped": .bool(c.yClipped),
        "thumbnail": .optional(c.thumbnail?.path),
    ]
    if let conf = c.confidences {
        o["vision"] = .object(conf.mapValues { JSON.double($0) })
        o["visionTop"] = .array(c.topLabels.map {
            .object(["identifier": .string($0.identifier), "confidence": .double($0.confidence)])
        })
        o["visionMilliseconds"] = .optional(c.classifyMilliseconds)
    } else {
        // NULL, NOT ZERO. Classification off is not a confidence of nought, and
        // the difference decides whether a frame was looked at or skipped.
        o["vision"] = .null
        o["visionTop"] = .null
        o["visionMilliseconds"] = .null
    }
    return .object(o)
}

private func clipJSON(_ r: ClipScan.Result, maxCandidates: Int) -> JSON {
    let exactY = r.yPlaneStride == 1
    let shown = r.candidates.prefix(maxCandidates)
    return .object([
        "video": infoJSON(r.info),
        "scan": .object([
            "framesDecoded": .int(r.decodedFrames),
            "wallSeconds": .double(r.scanSeconds),
            "framesPerSecond": .double(r.framesPerSecond),
            "ciMillisecondsPerFrame": .double(r.ciMillisecondsPerFrame),
            "yPlaneStride": .int(r.yPlaneStride),
            "yMeanIsExact": .bool(exactY),
            "classified": .bool(r.classified),
            "missingIndices": .array(r.missingIndices.map { .int($0) }),
            "workingColorSpace": .string(VideoReader.workingColorSpaceName),
        ]),
        "detector": detectorJSON(r.detection),
        "verdict": .string(r.verdict),
        "foundNothing": .bool(r.foundNothing),
        "candidateCount": .int(r.candidates.count),
        "candidatesReturned": .int(shown.count),
        "candidatesTrimmed": .bool(shown.count < r.candidates.count),
        "candidates": .array(shown.map { candidateJSON($0, exactY: exactY) }),
    ])
}

/// Base64 the written PNGs for the highest-confidence candidates.
private func inlineImages(from candidates: [ClipScan.Candidate], count: Int) -> (images: [Tool.InlineImage], bytes: Int, frames: [Int]) {
    guard count > 0 else { return ([], 0, []) }
    let ranked = candidates
        .filter { $0.thumbnail != nil }
        .sorted { ($0.confidence("lightning") ?? -1) > ($1.confidence("lightning") ?? -1) }
        .prefix(count)
    var out = [Tool.InlineImage]()
    var bytes = 0
    var frames = [Int]()
    for c in ranked {
        guard let url = c.thumbnail, let data = try? Data(contentsOf: url) else { continue }
        let b64 = data.base64EncodedString()
        bytes += b64.utf8.count
        out.append(Tool.InlineImage(base64: b64, mimeType: "image/png"))
        frames.append(c.frame)
    }
    return (out, bytes, frames)
}

// MARK: - the tool surface

enum Tools {

    static let all: [Tool] = [scan, scanFolder, segments, grade, contract]

    // MARK: walk_scan

    static let scan = Tool(
        name: "walk_scan",
        title: "Scan one clip",
        description: """
            Measure every frame of one video and return the candidate moments as \
            structured data: frame index, timecode, seconds, relative luminance \
            rise over a local median baseline, that rise in the clip's own robust \
            sigma, 10-bit Y-plane mean and max, Vision classifier confidences, and \
            a path to a written PNG of the frame. Reports the threshold it applied \
            and which half of it bound. "Nothing found" is returned as an answer, \
            not an empty result. Renders no keep/pitch verdict.
            """,
        inputSchema: schema(scanProperties.merging([
            "path": str("Absolute path to the video file."),
        ]) { a, _ in a }, required: ["path"]),
        readOnly: true,
        handler: { a in
            guard let path = a["path"]?.stringValue else { return .failure("walk_scan needs a path") }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure("No file at \(url.path)")
            }
            do {
                // Stride 1 by default for a SINGLE clip: one clip is the case
                // where exactness is affordable and where a number may be
                // compared against the references.
                let args = try ScanArgs.parse(a, defaultStride: 1)
                let result = try await ClipScan.run(url, options: args.options)
                let inline = inlineImages(from: result.candidates, count: args.inlineImages)
                var payload = clipJSON(result, maxCandidates: args.maxCandidates).objectValue ?? [:]
                payload["walk"] = .string(Walk.version)
                if !inline.images.isEmpty {
                    payload["inlineImages"] = .object([
                        "frames": .array(inline.frames.map { .int($0) }),
                        "base64Bytes": .int(inline.bytes),
                        "note": .string("Ranked by lightning confidence. Every candidate also has a thumbnail path; read those instead when there are many."),
                    ])
                }
                return .ok(.object(payload), images: inline.images)
            } catch is CancellationError {
                return .failure("Cancelled.")
            } catch {
                return .failure("scan failed: \(error)")
            }
        })

    // MARK: walk_scan_folder

    static let scanFolder = Tool(
        name: "walk_scan_folder",
        title: "Walk a folder",
        description: """
            "Go walk this folder." Enumerate the video files in one or more folders \
            (or a mixture of files and folders) and scan every one, returning \
            per-clip results in the same shape as walk_scan. Reports what it looked \
            at, what it skipped, what it could not read, and which clips returned \
            nothing — an empty folder and a clip with no candidates are two \
            different answers and both are stated. Defaults to the fast Y-plane \
            stride because triage is the job; walk_scan one clip for exact figures. \
            This enumerates and scans. It does NOT rank a mixed folder by interest \
            — see ingest.dump in walk_contract for why.
            """,
        inputSchema: schema(scanProperties.merging([
            "path": str("Absolute path to a folder, or to a single video file."),
            "paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Several folders or files at once. Use instead of path, or alongside it."),
            ]),
            "recursive": bool("Descend into subfolders. Off by default: 'walk this folder' means this folder, and a recursive default is how a scan quietly becomes a hundred times longer than expected.", default: false),
            "max_clips": int("Stop after this many clips."),
        ]) { a, _ in a }),
        readOnly: true,
        handler: { a in
            var inputs = [URL]()
            if let p = a["path"]?.stringValue { inputs.append(URL(fileURLWithPath: p)) }
            if let list = a["paths"]?.arrayValue {
                inputs.append(contentsOf: list.compactMap(\.stringValue).map { URL(fileURLWithPath: $0) })
            }
            guard !inputs.isEmpty else { return .failure("walk_scan_folder needs path or paths") }
            do {
                let args = try ScanArgs.parse(a, defaultStride: 4)
                var find = ClipFinder.Options()
                find.recursive = a["recursive"]?.boolValue ?? false
                if let cap = a["max_clips"]?.intValue {
                    guard cap > 0 else { throw ToolError("max_clips must be positive") }
                    find.maximumClips = cap
                }
                let folder = try await ClipScan.folder(inputs, find: find, options: args.options)
                let payload: JSON = .object([
                    "walk": .string(Walk.version),
                    "asked": .array(inputs.map { .string($0.path) }),
                    "search": .object([
                        "recursive": .bool(find.recursive),
                        "foldersSearched": .array(folder.found.directoriesSearched.map { .string($0.path) }),
                        "clipsFound": .int(folder.found.clips.count),
                        "skippedNonVideo": .array(folder.found.skipped.map { .string($0.lastPathComponent) }),
                        "videoExtensions": .array(ClipFinder.videoExtensions.sorted().map { .string($0) }),
                        "nothingToScan": .bool(folder.found.foundNothing),
                        "verdict": .string(folder.found.verdict),
                    ]),
                    "totals": .object([
                        "clipsScanned": .int(folder.clips.count),
                        "framesScanned": .int(folder.totalFramesScanned),
                        "candidates": .int(folder.totalCandidates),
                        "clipsWithNothingFound": .int(folder.clipsWithNothing.count),
                        "clipsUnreadable": .int(folder.failures.count),
                    ]),
                    "verdict": .string(folder.verdict),
                    "clips": .array(folder.clips.map { clipJSON($0, maxCandidates: args.maxCandidates) }),
                    "failures": .array(folder.failures.map {
                        .object(["path": .string($0.url.path), "reason": .string($0.reason)])
                    }),
                    "note": .string("A candidate is a whole-frame luminance rise, classified afterwards. On non-storm footage a high count means the light moved, not that the clip is interesting."),
                ])
                return .ok(payload)
            } catch is CancellationError {
                return .failure("Cancelled.")
            } catch {
                return .failure("folder scan failed: \(error)")
            }
        })

    // MARK: walk_segments

    static let segments = Tool(
        name: "walk_segments",
        title: "Build cut ranges",
        description: """
            Scan a clip, then turn each candidate into a cut range with handles \
            either side. Overlapping ranges coalesce. Where the clip cannot supply \
            the handles asked for, the SHORTFALL IS REPORTED rather than silently \
            clamped: an event 0.70 s into a clip has 0.70 s of lead-in and the \
            result says so. Without out_dir nothing is written and the ranges come \
            back as a plan. With out_dir each segment is re-encoded to its own \
            HEVC Main10 HLG .mov and verified by reading the frames back.
            """,
        inputSchema: schema([
            "path": str("Absolute path to the video file."),
            "handles": num("Seconds of handle on both sides. Overridden by lead_seconds / tail_seconds.", default: 1.0),
            "lead_seconds": num("Seconds before each event."),
            "tail_seconds": num("Seconds after each event."),
            "out_dir": str("Write the segments here. Omit to get the plan without writing anything."),
            "fps": int("Output frame rate. Retiming is exact integer-rational, so 60 to 30 is a true 2/1.", default: 30),
            "from_frame": int("First frame to consider, inclusive."),
            "to_frame": int("Last frame to consider, exclusive."),
            "vision": bool("Classify candidates before building ranges.", default: false),
            "sigma": num("Robust-sigma multiple for the statistical threshold.", default: 12),
            "floor": num("Absolute floor on relative luminance rise, as a fraction.", default: 0.01),
        ], required: ["path"]),
        readOnly: false,
        handler: { a in
            guard let path = a["path"]?.stringValue else { return .failure("walk_segments needs a path") }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure("No file at \(url.path)")
            }
            do {
                var opts = ClipScan.Options.triage()
                opts.classify = a["vision"]?.boolValue ?? false
                opts.thumbnailDirectory = nil
                if let k = a["sigma"]?.doubleValue { opts.detector.sigmaMultiple = k }
                if let f = a["floor"]?.doubleValue { opts.detector.minimumRelativeRise = f }
                if let lo = a["from_frame"]?.intValue ?? nil, let hi = a["to_frame"]?.intValue, hi > lo {
                    opts.frames = lo..<hi
                }
                let both = a["handles"]?.doubleValue ?? 1.0
                let lead = a["lead_seconds"]?.doubleValue ?? both
                let tail = a["tail_seconds"]?.doubleValue ?? both
                guard lead >= 0, tail >= 0 else { throw ToolError("handles cannot be negative") }
                let fps = Int32(a["fps"]?.intValue ?? 30)
                guard fps > 0 else { throw ToolError("fps must be positive") }

                let scanned = try await ClipScan.run(url, options: opts)
                guard !scanned.candidates.isEmpty else {
                    return .ok(.object([
                        "walk": .string(Walk.version),
                        "video": infoJSON(scanned.info),
                        "detector": detectorJSON(scanned.detection),
                        "verdict": .string(scanned.verdict),
                        "segments": .array([]),
                        "wrote": .array([]),
                        "note": .string("Nothing to cut. No segment written. That is an answer — see the detector block for the threshold that was applied and which half bound."),
                    ]))
                }

                // The clamp, and where it came from. See ClipScan.Result.segmentClamp
                // — clamping against the decoded count is right for a whole
                // clip and produces a FALSE shortfall for a sub-range, which is
                // how this was found.
                let clamp = scanned.segmentClamp
                let builder = SegmentBuilder(totalFrames: clamp.totalFrames,
                                             frameDuration: scanned.info.frameDuration)
                let built = builder.segments(forEventFrames: scanned.candidates.map(\.frame),
                                             leadSeconds: lead, tailSeconds: tail)

                var segmentsJSON = [JSON]()
                var wrote = [JSON]()
                let outDir = a["out_dir"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
                if let outDir {
                    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                }
                let writer = VideoWriter(options: .init(targetFrameRate: fps))
                let reader = outDir != nil ? try await VideoReader(url: url) : nil
                let stem = url.deletingPathExtension().lastPathComponent

                for (n, s) in built.enumerated() {
                    segmentsJSON.append(.object([
                        "index": .int(n + 1),
                        "eventFrame": .int(s.eventIndex),
                        "startFrame": .int(s.startFrame),
                        "endFrameExclusive": .int(s.endFrame),
                        "frameCount": .int(s.frameCount),
                        "seconds": .double(s.seconds),
                        "requestedLeadSeconds": .double(s.requestedLeadSeconds),
                        "requestedTailSeconds": .double(s.requestedTailSeconds),
                        "leadSeconds": .double(s.leadSeconds),
                        "tailSeconds": .double(s.tailSeconds),
                        "leadShortfallSeconds": .double(s.leadShortfallSeconds),
                        "tailShortfallSeconds": .double(s.tailShortfallSeconds),
                        "isShort": .bool(s.isShort),
                        "shortfallNote": .string(s.shortfallNote),
                    ]))
                    guard let outDir, let reader else { continue }
                    let out = outDir.appendingPathComponent(
                        String(format: "%@_seg%02d_f%06d.mov", stem, n + 1, s.eventIndex))
                    do {
                        let r = try await writer.write(reader, frames: s.frames, to: out)
                        wrote.append(.object([
                            "path": .string(r.url.path),
                            "framesRequested": .int(r.framesRequested),
                            "framesAppended": .int(r.framesAppended),
                            "framesDecodable": .optional(r.framesDecodable),
                            "verified": .bool(r.verified),
                            "verificationNote": .string(r.verificationNote),
                            "outputSeconds": .double(r.outputSeconds),
                            "outputFrameRate": .double(r.outputFrameRate),
                            "retime": .string("\(r.retimeRatio.numerator)/\(r.retimeRatio.denominator)"),
                            "codec": .string(r.codec),
                            "bitDepth": .optional(r.bitDepth),
                            "transferFunction": .optional(r.transferFunction),
                            "bytes": .int(r.bytes),
                            "encodeFramesPerSecond": .double(r.framesPerSecondEncoded),
                        ]))
                    } catch {
                        wrote.append(.object(["path": .string(out.path),
                                              "failed": .string("\(error)")]))
                    }
                }

                let short = built.filter(\.isShort).count
                return .ok(.object([
                    "walk": .string(Walk.version),
                    "video": infoJSON(scanned.info),
                    "detector": detectorJSON(scanned.detection),
                    "verdict": .string(scanned.verdict),
                    "requested": .object(["leadSeconds": .double(lead), "tailSeconds": .double(tail),
                                          "outputFps": .int(Int(fps))]),
                    "clamp": .object([
                        "totalFrames": .int(clamp.totalFrames),
                        "measured": .bool(clamp.measured),
                        "basis": .string(clamp.basis),
                        "note": .string("Handle shortfalls are computed against this. When measured is false only part of the clip was decoded, so a reported shortfall is a limit of the scan window, not of the clip."),
                    ]),
                    "segmentCount": .int(built.count),
                    "segmentsShortOfHandles": .int(short),
                    "segments": .array(segmentsJSON),
                    "dryRun": .bool(outDir == nil),
                    "wrote": .array(wrote),
                    "note": .string(outDir == nil
                        ? "No out_dir given, so nothing was written. These are the ranges that would be cut."
                        : "Re-encode path only. Passthrough is open defect task #721 — 180x faster and silently 22 frames short with every success signal returning true. Segments carry no audio (video.audio is not implemented)."),
                ]))
            } catch is CancellationError {
                return .failure("Cancelled.")
            } catch {
                return .failure("segments failed: \(error)")
            }
        })

    // MARK: walk_grade

    static let grade = Tool(
        name: "walk_grade",
        title: "Grade a still",
        description: """
            Apply Walk's HLG-to-SDR still grade and report what it changed: channel \
            means and luma before (raw file values, colour management disabled) and \
            after (managed, linear 709), plus the cast check — the change in channel \
            spread, which is positive when the grade itself introduced a colour cast. \
            Refuses to grade at all if the baseline measurement comes back NaN, \
            because a grade that cannot state its starting point is a guess wearing a \
            number. Omit output to measure without writing a file.
            """,
        inputSchema: schema([
            "input": str("Absolute path to the still. Read with colour management disabled, so the numbers are the file's own."),
            "output": str("Where to write the graded PNG. Omit to measure only."),
            "look": .object([
                "type": .string("string"),
                "enum": .array([.string("neutral"), .string("dramatic")]),
                "description": .string("neutral is exposure 1.0, contrast 1.0, no vibrance. dramatic is the shipped look."),
                "default": .string("dramatic"),
            ]),
            "target_nits": num("Display target in cd/m². The BT.2390 system gamma is derived from it: 1.2 + 0.42*log10(Lw/1000), so 100 nits gives 0.78 and values above 1 darken shadows instead of lifting them.", default: 100),
        ], required: ["input"]),
        readOnly: false,
        handler: { a in
            guard let input = a["input"]?.stringValue else { return .failure("walk_grade needs an input") }
            let look = a["look"]?.stringValue ?? "dramatic"
            guard ["neutral", "dramatic"].contains(look.lowercased()) else {
                return .failure("look must be neutral or dramatic, not \(look)")
            }
            let nits = a["target_nits"]?.doubleValue ?? 100
            guard nits > 0 else { return .failure("target_nits must be positive") }
            do {
                let r = try StillGrade.run(input: URL(fileURLWithPath: input),
                                           output: a["output"]?.stringValue.map { URL(fileURLWithPath: $0) },
                                           lookName: look, targetNits: nits)
                func reading(_ x: HLGGrade.Reading) -> JSON {
                    .object(["r": .double(x.r), "g": .double(x.g), "b": .double(x.b),
                             "luma": .double(x.luma), "spread": .double(x.spread),
                             "valid": .bool(x.valid)])
                }
                return .ok(.object([
                    "walk": .string(Walk.version),
                    "input": .string(r.input.path),
                    "output": .optional(r.output?.path),
                    "wrote": .bool(r.output != nil),
                    "look": .string(r.lookName),
                    "targetNits": .double(r.targetNits),
                    "systemGamma": .double(r.systemGamma),
                    "width": .int(r.width), "height": .int(r.height),
                    "megapixels": .double(r.megapixels),
                    "before": reading(r.before),
                    "after": reading(r.after),
                    "castCheck": .object([
                        "spreadDelta": .double(r.castDelta),
                        "addedCast": .bool(r.addedCast),
                        "note": .string(r.castNote),
                        "threshold": .double(0.01),
                    ]),
                    "milliseconds": .double(r.milliseconds),
                    "note": .string("before is raw HLG file values with colour management disabled; after is managed linear 709. They are not directly comparable as absolutes — the cast check compares SPREAD, which is what survives the change of space."),
                ]))
            } catch {
                return .failure("grade failed: \(error)")
            }
        })

    // MARK: walk_contract

    static let contract = Tool(
        name: "walk_contract",
        title: "Version and capability contract",
        description: """
            This build's version, every capability present with the version that \
            introduced it, and every capability explicitly ABSENT with the reason \
            it is absent. Pass expect to verify a consumer written against a \
            specific Walk: equal passes, an older Walk fails because capability may \
            be missing, and a NEWER Walk also fails because the consumer's \
            instructions may describe behaviour that has since changed. Call this \
            before relying on anything Walk does; absence is not silence here, and \
            a capability not listed is one Walk does not have.
            """,
        inputSchema: schema([
            "expect": str("A version string like 0.4.0 to check this build against."),
        ]),
        readOnly: true,
        handler: { a in
            var payload: [String: JSON] = [
                "walk": .string(Walk.version),
                "capabilities": .object(Walk.capabilities.mapValues { JSON.string($0) }),
                "notImplemented": .array(Walk.notImplemented.sorted().map { .string($0) }),
                "notImplementedReasons": .object(Walk.notImplementedReasons.mapValues { JSON.string($0) }),
                "mcp": .object([
                    "transport": .string("stdio"),
                    "protocolVersions": .array(Protocols.all.map { .string($0) }),
                    "modernVersions": .array(Protocols.modern.map { .string($0) }),
                    "legacyVersions": .array(Protocols.legacy.map { .string($0) }),
                    "tools": .array(Tools.all.map { .string($0.name) }),
                ]),
                "note": .string("capabilities and notImplemented are disjoint, and a test fails if they are not. Every notImplemented entry must carry a reason, and a test fails if one does not."),
            ]
            if let expect = a["expect"]?.stringValue {
                let c = Walk.check(expecting: expect)
                payload["check"] = .object([
                    "expected": .string(c.expected),
                    "actual": .string(c.actual),
                    "ok": .bool(c.ok),
                    "detail": .string(c.detail),
                ])
                // A MISMATCH IS A TOOL ERROR, not a field the caller may miss.
                // The point of the contract is that a stale consumer FAILS
                // LOUDLY; returning ok:false inside a success result would let a
                // model read past it, which is the drift the contract exists to
                // stop.
                if !c.ok {
                    let serialized = (try? JSON.object(payload).line())
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return .failure("CONTRACT MISMATCH — \(c.detail) (this build is \(c.actual), the consumer expects \(c.expected))\n\(serialized)")
                }
            }
            return .ok(.object(payload))
        })
}
