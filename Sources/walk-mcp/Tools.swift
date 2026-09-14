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
    /// The coach for this call. Built from the arguments once, so a folder walk
    /// resolves the criteria file once rather than per clip.
    var coach = Coaching.Coach()

    /// Hard ceiling on inline images regardless of what was asked for.
    ///
    /// MEASURED on this material and the reason the cap exists: a 640-pixel-wide
    /// display PNG off a 4K frame runs to a few hundred kilobytes, roughly a
    /// third larger again once base64-encoded. #507 records one GoPro clip
    /// producing 38 candidates. Inlining all of them would be tens of megabytes
    /// of images for one clip and the conversation would end before the operator
    /// saw a single frame. Paths are always returned; bytes are rationed.
    static let inlineImageCeiling = 6

    static func parse(_ a: JSON, defaultStride: Int,
                      defaultMaxCandidates: Int = 200) throws -> ScanArgs {
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
        s.coach = Coaching.Coach(explicit: a["criteria"]?.stringValue
            .map { URL(fileURLWithPath: $0) })
        s.inlineImages = min(a["inline_images"]?.intValue ?? 0, inlineImageCeiling)
        s.maxCandidates = max(1, a["max_candidates"]?.intValue ?? defaultMaxCandidates)
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
    "criteria": str("Absolute path to a coaching criteria file, which is what a verdict is rendered from (decision #499). Omit to use WALK_CRITERIA, then ~/Library/Application Support/Walk/criteria.json. Walk ships no criteria, so with none installed every result carries coaching.available=false and the reason — read that field instead of inferring a verdict."),
    "max_candidates": int("Ceiling on how many candidate rows come back PER CLIP — 200 for walk_scan, 10 for walk_scan_folder, because a full folder walk of 235 candidates serializes to about 200 KB. When it trims, it keeps the highest lightning confidence first and then the largest luminance rise, and says so in candidatesSelectedBy. The counts, the verdict and the thresholds always reflect every candidate found."),
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
        // #740 DEFECT 1. sigma = relativeRise / robustSigma, and robustSigma is
        // ONE CONSTANT for the clip — so per candidate the two fields carry the
        // same ranking and the same information. A model reading `relativeRise`
        // high AND `sigma` high concludes two measurements agree. They do not
        // agree; one is the other rescaled. Reproduced on clip 0012: rise
        // 18.483% / sigma 737.0 and rise 3.689% / sigma 147.1, both at exactly
        // 1/2.508e-04. Stated here rather than left for a reader to derive.
        "sigmaDerivation": .string("Each candidate's `sigma` is that candidate's `relativeRise` divided by this `robustSigma`. robustSigma is one constant for the whole clip, so within a clip `sigma` is `relativeRise` rescaled: identical ranking, no independent information, NOT a second measurement corroborating the first. It is useful only for comparing candidates across different clips."),
        "note": .string("threshold = max(statistical, floor). boundBy says which half decided, so a reader can tell whether the answer came from the clip or from the constant. scaleCollapsed means more than half the frames sat exactly on their local median, so the clip supplied no measurable noise scale. NOTE THE TWO SENSES OF THE WORD: the clip-level `verdict` string is the DETECTOR's — how many candidates cleared which threshold — and predates #513. The coaching verdict is in `coaching`. The detector field keeps its name and meaning so a 0.4.1 consumer is not broken."),
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

/// The candidates to return when there are more than the caller wants.
///
/// RANK, NOT FRAME ORDER, AND THE MEASUREMENT IS THE REASON. A full walk of the
/// operator's own GoPro folder — 8 clips, 235 candidates — serializes to
/// 201,889 bytes, roughly 50k tokens for one tool result. Trimming is therefore
/// not a corner case for this tool, it is the normal path, and `prefix()` would
/// hand back whichever candidates happen to sit earliest in the clip. On that
/// footage the highest `lightning` confidence anywhere is 0.0010 and on the
/// storm clip it is 0.6616, so the confidence is exactly the axis that
/// distinguishes them — throwing it away to keep frame order would discard the
/// only signal that makes a trimmed list readable.
///
/// Counts and the verdict always reflect EVERY candidate found, and the result
/// says both how it selected and that it trimmed.
private func selectCandidates(_ all: [ClipScan.Candidate], limit: Int)
    -> (rows: [ClipScan.Candidate], selectedBy: String) {
    guard all.count > limit else { return (all, "all") }
    let classified = all.contains { $0.confidences != nil }
    let ranked = all.sorted { a, b in
        if classified {
            let x = a.confidence("lightning") ?? -1, y = b.confidence("lightning") ?? -1
            if x != y { return x > y }
        }
        return a.relativeRise > b.relativeRise
    }
    // Back into frame order once chosen, so a reader can still follow the clip.
    let rows = ranked.prefix(limit).sorted { $0.frame < $1.frame }
    return (Array(rows),
            classified ? "highest lightning confidence, then largest luminance rise"
                       : "largest luminance rise (classification was off)")
}

// MARK: - the coaching verdict (#513)

/// The band SHAPE, stated once per response whether or not a verdict rendered.
///
/// A host that only ever sees `available: false` must still be able to learn
/// what Walk's output IS — #513 makes the bands the product, and an absent
/// verdict that also hides the shape teaches a consumer that Walk is a readout.
/// That is the mistake the old instructions string made in prose.
private func bandShapeJSON() -> JSON {
    .array(Coaching.Band.allCases.sorted { $0.order < $1.order }.map { band in
        .object([
            "band": .string(band.rawValue),
            "label": .string(band.label),
            "promise": .string(band.promise),
            "namesOneChange": .bool(band.requiresChange),
            "asksForwardQuestion": .bool(band.requiresForwardQuestion),
        ])
    })
}

private func lessonsJSON(_ lessons: [Coaching.Lesson]) -> JSON {
    .array(lessons.map {
        .object(["id": .string($0.id), "headline": .string($0.headline),
                 "detail": .string($0.detail), "origin": .string($0.origin)])
    })
}

/// The criteria state, once per response rather than once per clip: whether a
/// verdict can be rendered at all, and if not, why and where Walk looked.
private func coachStateJSON(_ coach: Coaching.Coach) -> JSON {
    var o: [String: JSON] = [
        "available": .bool(coach.isReady),
        "forwardQuestion": .string(Coaching.forwardQuestion),
        "bands": bandShapeJSON(),
        "lessons": lessonsJSON(Coaching.lessons),
    ]
    if let reason = coach.unavailableReason {
        o["reason"] = .string(reason)
        o["searched"] = .array((coach.resolution?.searched ?? []).map { .string($0) })
        o["note"] = .string("coaching.available is false, so no band was assigned to anything. The candidates below are measured and unjudged. Do not present a verdict Walk did not render.")
    } else if let c = coach.criteria {
        o["criteria"] = .object([
            "version": .string(c.header.version),
            "walk": .string(c.header.walk),
            "owner": .string(c.header.owner),
            "established": .string(c.header.established),
            "source": .string(c.source),
            "rules": .int(c.rules.count),
            "note": .optional(c.header.note),
        ])
        o["note"] = .string("Each verdict names the rule that fired and the decision that established it, with the measurements it read underneath. The numbers are evidence, not the answer.")
    }
    return .object(o)
}

private func verdictJSON(_ v: Coaching.Verdict) -> JSON {
    .object([
        "band": .string(v.band.rawValue),
        "label": .string(v.band.label),
        "frame": .int(v.frame),
        "timecode": .string(v.timecode),
        "seconds": .double(v.seconds),
        "reason": .string(v.reason),
        // Band 2 only, and never null there — the initializer refuses it.
        "change": .optional(v.change),
        "forwardQuestion": .optional(v.forwardQuestion),
        "nextFlight": .string(v.nextFlight),
        "rule": .string(v.ruleID),
        "origin": .string(v.origin),
        "evidence": .array(v.evidence.map {
            .object(["measurement": .string($0.measurement),
                     "measured": .double($0.measured),
                     "required": .string($0.required),
                     "held": .bool($0.held)])
        }),
        "thumbnail": .optional(v.thumbnail?.path),
    ])
}

/// Per clip: the verdicts and the counts. The shape, the lessons and the reason
/// for an absence live once at the top level — a folder walk of eight clips
/// repeating them is the 50k-token result 0.4.1 was built to stop.
private func clipCoachingJSON(_ report: Coaching.Report) -> JSON {
    var o: [String: JSON] = [
        "available": .bool(report.available),
        "headline": .string(report.headline),
    ]
    guard report.available else { return .object(o) }
    let counts = report.counts
    o["counts"] = .object(Dictionary(uniqueKeysWithValues:
        Coaching.Band.allCases.map { ($0.rawValue, JSON.int(counts[$0] ?? 0)) }))
    o["verdicts"] = .array(report.verdicts.map(verdictJSON))
    // NOT BANDED, AND NOT SILENTLY EITHER. A candidate no rule covered would
    // otherwise vanish between a measured list and a judged one.
    o["uncoveredCandidateFrames"] = .array(report.uncovered.map { .int($0) })
    if !report.malformed.isEmpty {
        o["malformed"] = .array(report.malformed.map { .string($0) })
    }
    return .object(o)
}

private func clipJSON(_ r: ClipScan.Result, maxCandidates: Int,
                      coach: Coaching.Coach? = nil) -> JSON {
    let exactY = r.yPlaneStride == 1
    let (shown, selectedBy) = selectCandidates(r.candidates, limit: maxCandidates)
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
            // #740 DEFECT 2. `relativeRise` never named its space, and a careful
            // reviewer measuring the gamma-encoded Y plane correctly could not
            // reproduce it and filed the engine as broken. Both figures were
            // right; they are different quantities. Clip 0012 frame 2347 is
            // +36.03% in this pinned linear space and +6.02% on the Y plane;
            // frame 2388 is +3.69% here and +0.87% there — so the ratio is not
            // even constant and no single multiplier converts between them.
            "relativeRiseMeasuredIn": .string("\(VideoReader.workingColorSpaceName), pinned. `ciLuma`, `baseline`, `delta`, `relativeRise` and `relativeRisePercent` are all measured in this LINEAR space. `yMean` and `yMax` are gamma-encoded 10-bit Y-plane code values. The two are not comparable and no fixed factor converts between them: clip 0012 frame 2347 is +36.03% linear against +6.02% on the Y plane, and frame 2388 is +3.69% against +0.87%. Both Y-plane figures are over the detector's own local-median baseline; 2388 against frame 2387 alone is +0.79%, which is a different baseline rule and not one the engine applies."),
        ]),
        "detector": detectorJSON(r.detection),
        "verdict": .string(r.verdict),
        "foundNothing": .bool(r.foundNothing),
        "candidateCount": .int(r.candidates.count),
        "candidatesReturned": .int(shown.count),
        "candidatesTrimmed": .bool(shown.count < r.candidates.count),
        "candidatesSelectedBy": .string(selectedBy),
        "candidates": .array(shown.map { candidateJSON($0, exactY: exactY) }),
        // ADDITIVE, AND DELIBERATELY AFTER THE MEASUREMENTS IN THE OBJECT.
        // #513: the verdict is the product and the numbers are the evidence
        // under it. Nothing above this line changed shape, so a 0.4.1 consumer
        // reads this result unchanged.
        "coaching": coach.map { clipCoachingJSON($0.report(for: r)) } ?? .null,
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

    static let all: [Tool] = [scan, scanFolder, proofSheet, segments, grade, contract]

    // MARK: walk_scan

    static let scan = Tool(
        name: "walk_scan",
        title: "Scan one clip",
        description: """
            Measure every frame of one video and return the candidate moments as \
            structured data: frame index, timecode, seconds, relative luminance \
            rise over a local median baseline measured in PINNED LINEAR BT.2020 \
            light (`scan.relativeRiseMeasuredIn` names the space, and a \
            gamma-encoded Y-plane measurement of the same event is a different, \
            much smaller number that no fixed factor converts to), that same rise \
            divided by the clip's one robust-sigma constant — a rescaling of the \
            previous field and not a second measurement, see \
            `detector.sigmaDerivation` — 10-bit Y-plane mean and max, Vision \
            classifier confidences, and \
            a path to a written PNG of the frame. Reports the threshold it applied \
            and which half of it bound. "Nothing found" is returned as an answer, \
            not an empty result. Then RENDERS THE COACHING VERDICT over those \
            measurements — three bands, each with a reason and a next-flight \
            lesson (#513) — from the criteria file that carries Andy's judgment. \
            No criteria ship with Walk, so read `coach.available`: when it is \
            false the result says why, the candidates are measured and unjudged, \
            and no band has been assigned to anything.
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
                var payload = clipJSON(result, maxCandidates: args.maxCandidates,
                                       coach: args.coach).objectValue ?? [:]
                payload["walk"] = .string(Walk.version)
                payload["coach"] = coachStateJSON(args.coach)
                if !inline.images.isEmpty {
                    payload["inlineImages"] = .object([
                        "frames": .array(inline.frames.map { .int($0) }),
                        "base64Bytes": .int(inline.bytes),
                        // #740 DEFECT 3 — THE THUMBNAILS WERE NOT IN THE ORDER
                        // THEY WERE READ AS BEING IN, AND THIRTEEN VERDICTS
                        // LANDED ON THE WRONG THIRTEEN FRAMES.
                        //
                        // A session rendered a proof sheet from these images,
                        // renamed them f_01…f_13, and stated they were in card
                        // order. They were in chronological order: f_01 was
                        // card 13. Caught only because the reviewer SHA-256'd
                        // each file against the frame indices.
                        //
                        // Inline images are an ORDERED, UNLABELLED sequence —
                        // nothing in the image itself says which frame it is —
                        // and their order is confidence rank, which is NOT the
                        // order of the `candidates` array. `frames` is the
                        // mapping and it is positional. Say so, rather than
                        // leaving the correspondence to be assumed.
                        "note": .string("ORDER MATTERS AND IT IS NOT THE CANDIDATE ORDER. These images are ranked by lightning confidence, descending; the `candidates` array is in frame order. The nth image is `frames[n]` — use that mapping, never the position in `candidates`, and never a number you assigned yourself. If you render a sheet from these, label every cell with its frame index from `frames` and do not renumber them 1..n: a renumbered sheet has already produced thirteen verdicts on the wrong thirteen frames. Every candidate also carries a `thumbnail` file path whose filename ends in _f<frame>.png, which is self-labelling; prefer those when there are many."),
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
            — see ingest.dump in walk_contract for why. Each clip also carries the \
            coaching verdict (#513) when a criteria file is installed; `coach` at \
            the top level says whether one was, and why not when it was not.
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
                // TEN PER CLIP BY DEFAULT, AND THAT IS A MEASURED NUMBER.
                // A full walk of the operator's GoPro folder returns 235
                // candidates across 8 clips and serializes to 201,889 bytes —
                // about 50k tokens for one tool result, on the tool whose whole
                // job is "go walk this folder". The counts, the verdict and the
                // per-clip thresholds are unaffected by trimming; only the rows
                // are, and they are chosen by rank. Raise it with
                // max_candidates when a clip is worth reading in full, or call
                // walk_scan on that one clip.
                let args = try ScanArgs.parse(a, defaultStride: 4, defaultMaxCandidates: 10)
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
                    "coach": coachStateJSON(args.coach),
                    "clips": .array(folder.clips.map {
                        clipJSON($0, maxCandidates: args.maxCandidates, coach: args.coach)
                    }),
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


    // MARK: walk_proof_sheet

    /// JSON FOR THE SHEET IS BUILT IN WalkKit, NOT HERE, and that is deliberate
    /// even though every other tool in this file assembles its own payload.
    /// `ProofSheet` has to serialize the manifest to disk anyway — the artifact
    /// is the manifest — so a second encoder here would be two descriptions of
    /// one document, drifting apart the moment a field is added. This handler
    /// parses arguments and hands back what the engine wrote.
    static let proofSheet = Tool(
        name: "walk_proof_sheet",
        title: "Time-sampled proof sheet",
        description: """
            "What is in this folder?" Emit a TIME-SAMPLED proof sheet over mixed \
            media: every still is one cell, every clip is a strip of frames spaced \
            evenly across its whole duration (12 by default), tone-mapped for \
            display and written as JPEGs, described by one manifest.json. \
            DISTINCT FROM walk_scan, which returns the frames a luminance detector \
            flagged and returns nothing at all for a clip whose light never \
            changes: this samples time, so every clip produces a picture of its \
            arc. Each cell carries its frame index, timecode and seconds; each \
            item carries dimensions, fps, duration, codec and transfer function, \
            and for a DJI clip with a sibling .SRT the shutter and ISO \
            DISTRIBUTION over the whole file plus a 180-degree shutter comparison \
            against 1/(2 x fps). Every cell also carries a tiny blurred \
            placeholder as an inline data URI, and the manifest is written before \
            any pixels are decoded and rewritten as cells land, so a viewer can \
            lay the sheet out immediately and watch it resolve — read `status`, \
            which is "sampling" until it is "complete". WALK EMITS THE DATA AND \
            NOT A PAGE: there is no HTML here. IT DISPLAYS AND MEASURES AND DOES \
            NOT JUDGE — no band, no rank, no keep/pitch, and the shutter check is \
            a comparison to a named convention rather than a verdict on the \
            footage. The coaching verdict is walk_scan's, from the criteria file.
            """,
        inputSchema: schema([
            "path": str("Absolute path to a folder, or to a single video or still file."),
            "paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Several folders or files at once. Use instead of path, or alongside it."),
            ]),
            "out_dir": str("Where the cells and manifest.json are written. Defaults to a Walk folder under the user's Caches directory, named after the first input — a cache and not a temp directory, so the paths are still valid when the viewer reads them back."),
            "frames_per_clip": int("Frames sampled per clip, spaced evenly across the whole duration and each centered in its own slice — so no sample is frame 0, where a drone is still settling. Stills are always one cell.", default: 12),
            "cell_width": num("Longest edge of a sharp cell JPEG, in pixels.", default: 900),
            "placeholder_width": num("Longest edge of the inline blurred placeholder, in pixels. Kept tiny because it is carried as a base64 data URI on every cell in the manifest.", default: 20),
            "jpeg_quality": num("JPEG quality for the sharp cells, 0 to 1.", default: 0.72),
            "placeholders": bool("Emit the placeholder pass. Off skips it: the sheet is then one pass and faster overall, and it loses the progressive fill that is the reason this exists.", default: true),
            "recursive": bool("Descend into subfolders. Off by default, for the same reason walk_scan_folder is: a recursive default is how a sheet quietly becomes a hundred times longer than expected.", default: false),
            "max_items": int("Stop after this many items, clips and stills together."),
        ]),
        readOnly: false,
        handler: { a in
            var inputs = [URL]()
            if let p = a["path"]?.stringValue { inputs.append(URL(fileURLWithPath: p)) }
            if let list = a["paths"]?.arrayValue {
                inputs.append(contentsOf: list.compactMap(\.stringValue).map { URL(fileURLWithPath: $0) })
            }
            guard !inputs.isEmpty else { return .failure("walk_proof_sheet needs path or paths") }

            let name = inputs[0].lastPathComponent.isEmpty ? "sheet" : inputs[0].lastPathComponent
            let out = a["out_dir"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? ProofSheet.Options.defaultDirectory(name: name)
            var options = ProofSheet.Options(outputDirectory: out)
            if let n = a["frames_per_clip"]?.intValue {
                guard n >= 1, n <= 60 else { return .failure("frames_per_clip must be between 1 and 60") }
                options.framesPerClip = n
            }
            if let w = a["cell_width"]?.doubleValue {
                guard w >= 64, w <= 3840 else { return .failure("cell_width must be between 64 and 3840") }
                options.cellWidth = w
            }
            if let w = a["placeholder_width"]?.doubleValue {
                guard w >= 4, w <= 128 else {
                    return .failure("placeholder_width must be between 4 and 128 — it is carried inline on every cell, so a large one is multiplied by the whole sheet")
                }
                options.placeholderWidth = w
            }
            if let q = a["jpeg_quality"]?.doubleValue {
                guard q > 0, q <= 1 else { return .failure("jpeg_quality must be above 0 and at most 1") }
                options.jpegQuality = q
            }
            options.placeholders = a["placeholders"]?.boolValue ?? true
            options.recursive = a["recursive"]?.boolValue ?? false
            if let cap = a["max_items"]?.intValue {
                guard cap > 0 else { return .failure("max_items must be positive") }
                options.maximumItems = cap
            }

            do {
                let sheet = try await ProofSheet.run(inputs, options: options)
                // THE MANIFEST IS THE ARTIFACT AND IT IS NOT INLINED. MEASURED on
                // the operator's DJI folder: 96 cells, each carrying a base64
                // placeholder, is a manifest of roughly 90 KB — and the cells it
                // describes are hundreds of kilobytes each. Returning a path is
                // the same decision thumbnails took in 0.4.0 and for the same
                // reason: the conversation would die before the operator saw
                // anything. What comes back is where to look and what was
                // measured getting there.
                return .ok(.object([
                    "walk": .string(Walk.version),
                    "manifest": .string(sheet.manifest.path),
                    "directory": .string(sheet.directory.path),
                    "status": .string("complete"),
                    "verdict": .string(sheet.verdict),
                    "totals": .object([
                        "items": .int(sheet.items.count),
                        "clips": .int(sheet.items.filter { $0.kind == .clip }.count),
                        "stills": .int(sheet.items.filter { $0.kind == .still }.count),
                        "cells": .int(sheet.cellCount),
                        "cellsRendered": .int(sheet.readyCells),
                        "cellsFailed": .int(sheet.failedCells),
                        "itemsUnreadable": .int(sheet.items.filter { $0.error != nil }.count),
                    ]),
                    "search": .object([
                        "foldersSearched": .array(sheet.found.directoriesSearched.map { .string($0.path) }),
                        "skipped": .array(sheet.found.skipped.map {
                            .object(["name": .string($0.url.lastPathComponent),
                                     "reason": .string($0.reason)])
                        }),
                        "nothingToSheet": .bool(sheet.found.foundNothing),
                    ]),
                    "timings": .object([
                        "metadataSeconds": .double(sheet.metadataSeconds),
                        "placeholderSeconds": .double(sheet.placeholderSeconds),
                        "sharpSeconds": .double(sheet.sharpSeconds),
                        "totalSeconds": .double(sheet.totalSeconds),
                    ]),
                    "shutter": .array(sheet.items.compactMap { item in
                        guard let s = item.shutter else { return nil }
                        return .object([
                            "name": .string(item.url.lastPathComponent),
                            "medianDenominator": .double(s.medianDenominator),
                            "oneEightyDenominator": .double(s.oneEightyDenominator),
                            "stopsFromOneEighty": .double(s.stopsFromOneEighty),
                            "withinTolerance": .bool(s.withinTolerance),
                            "impliedShutterAngle": .double(s.impliedShutterAngle),
                        ])
                    }),
                    "judgment": .object([
                        "rendered": .bool(false),
                        "note": .string("A proof sheet DISPLAYS and MEASURES. Nothing here is banded, ranked, scored or sorted by interest, and the shutter comparison is a measurement against the 180-degree convention rather than a ruling on the footage. Walk's coaching verdict comes from walk_scan against a criteria file (#499, #513) and is a different call."),
                    ]),
                    "note": .string("Read manifest.json for the whole sheet: per item the dimensions, fps, duration, codec, transfer function, tone map applied and DJI telemetry distribution; per cell the frame index, timecode, seconds, sharp file path and an inline blurred placeholder. `status` is \"sampling\" while cells are still landing and \"complete\" when every cell that will exist is described."),
                ]))
            } catch is CancellationError {
                return .failure("Cancelled.")
            } catch {
                return .failure("proof sheet failed: \(error)")
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
                // REFUSE A MALFORMED RANGE RATHER THAN IGNORE IT, the way
                // walk_scan does. The first version of this silently dropped the
                // range when to_frame was missing or not greater than from_frame
                // — and then scanned the whole clip, which is a different answer
                // to a different question, returned without comment. A caller
                // who asked for frames 2300 onward and got the entire file has
                // no way to tell.
                let sFrom = a["from_frame"]?.intValue
                let sTo = a["to_frame"]?.intValue
                if sFrom != nil || sTo != nil {
                    let lo = sFrom ?? 0
                    guard let hi = sTo, hi > lo else {
                        throw ToolError("a frame range needs to_frame greater than from_frame (to_frame is exclusive)")
                    }
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
            a capability not listed is one Walk does not have. Also reports \
            whether a coaching verdict can be rendered on this host right now — \
            the three bands are built, the criteria that fill them are not \
            shipped, and coach.reason names where Walk looked for them.
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
                // THE COACHING SURFACE, STATED IN THE CONTRACT RATHER THAN
                // DISCOVERED BY A CONSUMER. #513 named the gap precisely:
                // app.proofSheet was declared with no statement that the sheet
                // does not judge — absence indistinguishable from success, in
                // the one surface built to prevent that.
                "coach": coachStateJSON(Coaching.Coach()),
                "note": .string("capabilities and notImplemented are disjoint, and a test fails if they are not. Every notImplemented entry must carry a reason, and a test fails if one does not. coach reports whether a coaching verdict can be rendered on this host right now, which is a different question from whether this build supports one."),
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
