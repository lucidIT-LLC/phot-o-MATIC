import Foundation
import CoreMedia
import WalkKit

// MARK: - shared output helpers

func err(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

func jsonEscape(_ s: String) -> String {
    var o = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        default: o.unicodeScalars.append(c)
        }
    }
    return o
}

struct Finding {
    let event: EventDetector.Event
    let sample: LumaSample?
    let labels: Classifier.Result?
}

// MARK: - walk scan

enum ScanCommand {

    struct Args {
        var path: String
        var json = false
        var frames: Range<Int>? = nil
        var noVision = false
        /// Skip the Y-plane pass. MEASURED cost of keeping it: 95.0 fps with,
        /// 274-429 fps without, because it is a full CPU pass over 8.3M pixels
        /// per frame. It is ON by default because it is the measurement that
        /// agrees with ffmpeg signalstats and carries the known answer.
        var fast = false
        var sigma: Double? = nil
        var floor: Double? = nil
        /// Coaching criteria (#499). Absent falls back to WALK_CRITERIA and then
        /// the installed default; absent everywhere is reported as absent.
        var criteria: String? = nil
    }

    static func parse(_ argv: [String]) -> Args {
        guard argv.count >= 3 else {
            err("""
                usage: walk scan <video> [--json] [--frames a-b] [--no-vision] [--fast]
                                 [--sigma <k>] [--floor <fraction>] [--criteria <file>]
                """)
        }
        var a = Args(path: argv[2])
        var i = 3
        while i < argv.count {
            switch argv[i] {
            case "--json": a.json = true
            case "--no-vision": a.noVision = true
            case "--fast": a.fast = true
            case "--frames":
                i += 1
                let parts = (i < argv.count ? argv[i] : "").split(separator: "-")
                guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), hi > lo else {
                    err("--frames wants a-b, e.g. --frames 2300-2400")
                }
                a.frames = lo..<hi
            case "--sigma":
                i += 1; a.sigma = i < argv.count ? Double(argv[i]) : nil
            case "--floor":
                i += 1; a.floor = i < argv.count ? Double(argv[i]) : nil
            case "--criteria":
                i += 1
                guard i < argv.count else { err("--criteria wants a path to a criteria file") }
                a.criteria = argv[i]
            default: err("unknown option \(argv[i])")
            }
            i += 1
        }
        return a
    }

    static func run(_ argv: [String]) async {
        let a = parse(argv)
        do {
            let reader = try await VideoReader(url: URL(fileURLWithPath: a.path))
            let info = reader.info
            if !a.json { printHeader(info, reader: reader) }

            var opts = FrameScanner.Options(frames: a.frames, computeYPlane: !a.fast)
            opts.yPlaneStride = 1
            let series = try await FrameScanner.scan(reader, options: opts)

            var detOpts = EventDetector.Options()
            if let s = a.sigma { detOpts.sigmaMultiple = s }
            if let f = a.floor { detOpts.minimumRelativeRise = f }
            let result = EventDetector(options: detOpts).detect(series)

            var findings = [Finding]()
            let classifier = Classifier()
            for e in result.events {
                var labels: Classifier.Result? = nil
                if !a.noVision {
                    if let frame = try? await reader.frame(at: e.index) {
                        labels = try? await classifier.classify(frame)
                    }
                }
                findings.append(Finding(event: e, sample: series.sample(at: e.index), labels: labels))
            }

            // ONE coach, built from the same arguments, used by both printers.
            // The judgment layer is not re-implemented here — the candidates go
            // to WalkKit's coach exactly as the MCP server's do.
            let coach = Coaching.Coach(explicit: a.criteria.map { URL(fileURLWithPath: $0) })
            let candidates = findings.map { candidate($0, reader: reader) }
            let coaching = coach.report(for: candidates)

            if a.json {
                printJSON(reader: reader, series: series, result: result,
                          findings: findings, coach: coach, coaching: coaching)
            } else {
                printText(reader: reader, series: series, result: result,
                          findings: findings, coaching: coaching)
            }
        } catch { err("scan failed: \(error)") }
    }

    /// The CLI measured a clip its own way; this is the same values in the
    /// shape the coach reads. No new measurement — every number comes out of the
    /// event, the sample and the classifier result already computed above.
    static func candidate(_ f: Finding, reader: VideoReader) -> ClipScan.Candidate {
        let e = f.event
        return ClipScan.Candidate(
            frame: e.index, timecode: reader.timecode(ofFrame: e.index), time: e.time,
            ciLuma: e.value, baseline: e.baseline, delta: e.delta,
            relativeRise: e.relativeRise, sigma: e.sigma, mergedFrames: e.mergedFrames,
            yMean: f.sample?.yMean, yMax: f.sample?.yMax,
            yClipped: f.sample?.yClipped ?? false,
            // nil, NOT an empty dictionary: --no-vision means unmeasured, and a
            // rule reading a confidence must not fire on a false zero.
            confidences: f.labels?.requested,
            topLabels: f.labels?.top.map { (identifier: $0.identifier, confidence: $0.confidence) } ?? [],
            classifyMilliseconds: f.labels?.milliseconds, thumbnail: nil)
    }

    static func printHeader(_ info: VideoInfo, reader: VideoReader) {
        print("file          \(info.url.lastPathComponent)")
        print(String(format: "video         %d x %d  (%.1f MP)  %@  %@bit  %.2f fps  %.2f s  ~%d frames  %.1f Mbit/s",
                     info.width, info.height, info.megapixels, info.codec,
                     info.bitDepth.map(String.init) ?? "?", info.fps, info.seconds,
                     info.estimatedFrameCount, info.estimatedDataRateMbps))
        print("colour        primaries \(info.colorPrimaries ?? "?")  transfer \(info.transferFunction ?? "?")  matrix \(info.yCbCrMatrix ?? "?")\(info.isHLGBT2020 ? "   [HLG BT.2020]" : "")")
        // TASK #740 DEFECT 2 — `rise` NEVER NAMED ITS SPACE, AND THAT OMISSION
        // MANUFACTURED A FALSE FINDING ABOUT THE ENGINE.
        //
        // A reviewer measured frame 2347 of clip 0012 at +6.2% on the native
        // 10-bit gamma-encoded Y plane, read `rise +36.030%` here, could not
        // reproduce it under any baseline, and correctly wrote down that `rise`
        // was not reproducible. Both measurements were right. They are different
        // quantities: `rise` is CIAreaAverage in PINNED LINEAR BT.2020 light,
        // hers was the gamma-encoded Y-plane mean. Nothing in the output said so.
        //
        // THE LINE THIS REPLACES WAS ALSO WRONG, and in the same family. It read
        // "the CIContext default is ExtendedLinearSRGB and measures 4.2x less of
        // the event". Decision #495's own figures say otherwise: the same event
        // measures +36.03% in pinned linear BT.2020, +36.34% in DEFAULT linear
        // sRGB — very slightly MORE, not 4.2x less — and +8.54% in an 8-bit sRGB
        // working space, which is where the 4.2x actually came from. The figure
        // was real and was attached to the wrong comparison, so a reader could
        // have used it to convert between two numbers it does not relate.
        print("working space \(VideoReader.workingColorSpaceName)  (pinned)")
        print("              The luma / base / delta / rise columns below are measured IN THIS SPACE.")
        print("              A gamma-encoded 10-bit Y-plane measurement of the same event is a DIFFERENT")
        print("              and much smaller number, and NOT by a fixed factor: clip 0012 frame 2347 is")
        print("              +36.03% here and +6.02% on the Y plane; frame 2388 is +3.69% here and +0.87%")
        print("              there. The Ymean and Ymax columns ARE Y-plane code values — they are not")
        print("              comparable with rise, and no single multiplier converts between them.")
    }

    static func printText(reader: VideoReader, series: LumaSeries,
                          result: EventDetector.Result, findings: [Finding],
                          coaching: Coaching.Report) {
        print(String(format: "scan          %d frames decoded in %.3f s = %.1f fps   CIAreaAverage %.3f ms/frame",
                     series.decodedFrames, series.wallSeconds, series.framesPerSecond,
                     series.ciMillisecondsPerFrame))
        if !series.missingIndices.isEmpty {
            print("MISSING       \(series.missingIndices.count) frame indices never delivered: \(series.missingIndices.prefix(20))")
        }
        print(String(format: "threshold     %.4f%% relative rise   (statistics %.4f%% at %.0fσ, floor %.4f%%, %@ bound)",
                     result.threshold * 100, result.statisticalThreshold * 100,
                     EventDetector.Options().sigmaMultiple, result.floorThreshold * 100,
                     result.boundBy.rawValue))
        print(String(format: "robust sigma  %.6g of relative rise (MAD-derived)", result.robustSigma))
        // TASK #740 DEFECT 1 — `sigma` IS NOT A SECOND MEASUREMENT AND THE TABLE
        // PRESENTED IT AS ONE.
        //
        // EventDetector: sigma = relativeRise / robustSigma, and robustSigma is
        // ONE CONSTANT FOR THE WHOLE CLIP. So within a clip the sigma column is
        // the rise column multiplied by 1/robustSigma — identical ranking, zero
        // independent information. Reproduced on this repository's own README
        // sample output, which is clip 0012 at robustSigma 2.508e-04:
        //   frame 2334   rise +18.483%   sigma 737.0   18.483 x 39.87 = 737.1
        //   frame 2388   rise  +3.689%   sigma 147.1    3.689 x 39.87 = 147.1
        // Printed side by side, a reader sees a raw value corroborated by a
        // robust statistic. It is one instrument reported twice. The column is
        // kept because it is the only figure that compares ACROSS clips, where a
        // bare percentage does not — but the output now says what it is rather
        // than leaving a reviewer to derive it. `DetectorTests` asserts the
        // identity so this statement can fail if the derivation ever changes.
        print("              The sigma column below is rise DIVIDED BY that one constant. One constant for")
        print("              the whole clip, so within this clip sigma is the rise column rescaled: the same")
        print("              ranking, no second opinion. It is there to compare candidates across clips.")
        print("              Two columns side by side read as two instruments agreeing. These are one twice.")
        print("result        \(result.verdict)")
        guard !findings.isEmpty else {
            print("")
            print("No candidate exceeded the threshold. That is a finding, not an empty result —")
            print("the floor is what makes it reachable; see EventDetector.Options.minimumRelativeRise.")
            return
        }
        print("")
        print("  frame    timecode      time      luma      base     delta      rise      sigma   Ymean    Ymax  lightning  storm")
        for f in findings {
            let e = f.event
            let y = f.sample?.yMean.map { String(format: "%8.3f", $0) } ?? "       -"
            let ym = f.sample?.yMax.map { String(format: "%6d%@", $0, (f.sample?.yClipped ?? false) ? "!" : " ") } ?? "      -"
            let light = f.labels.map { String(format: "%9.4f", $0.confidence("lightning")) } ?? "        -"
            let storm = f.labels.map { String(format: "%6.4f", $0.confidence("storm")) } ?? "     -"
            print(String(format: "  %5d  %@  %8.3f  %.6f  %.6f  %+.6f  %+7.3f%%  %9.1f %@ %@ %@ %@",
                         e.index, reader.timecode(ofFrame: e.index), e.time,
                         e.value, e.baseline, e.delta, e.relativeRise * 100, e.sigma,
                         y, ym, light, storm))
        }
        printCoaching(coaching)
    }

    /// #513: the verdict is the product and the numbers above are the evidence
    /// under it. This block replaced two lines that said the opposite — "Walk
    /// sorts and flags; the keep/pitch judgment is the operator's or Pixel's" —
    /// which was the standing doctrine until the ruling reversed it.
    static func printCoaching(_ r: Coaching.Report) {
        print("")
        guard r.available else {
            print("COACHING VERDICT  none rendered")
            for line in wrap(r.unavailableReason ?? "reason not recorded", width: 86) {
                print("  \(line)")
            }
            if !r.searched.isEmpty {
                print("  looked in:")
                for place in r.searched { print("    \(place)") }
            }
            print("")
            print("  The bands a criteria set fills:")
            for band in Coaching.Band.allCases.sorted(by: { $0.order < $1.order }) {
                print("    \(band.label)")
                for line in wrap(band.promise, width: 80) { print("      \(line)") }
            }
            printLessons(r)
            return
        }
        print("COACHING VERDICT  \(r.headline)")
        if let v = r.criteriaVersion, let owner = r.criteriaOwner {
            print("  criteria \(v) by \(owner) — \(r.criteriaSource ?? "?")")
        }
        for band in Coaching.Band.allCases.sorted(by: { $0.order < $1.order }) {
            let group = r.verdicts(in: band)
            guard !group.isEmpty else { continue }
            print("")
            print("  \(band.label)")
            for v in group {
                print("    frame \(v.frame)  \(v.timecode)")
                for line in wrap(v.reason, width: 78) { print("      \(line)") }
                if let change = v.change {
                    for line in wrap("WITH THIS: \(change)", width: 78) { print("      \(line)") }
                }
                // REQUIRED, NOT DECORATION — #513. It is the mechanism that
                // keeps a photographer moving instead of having work sorted.
                if let q = v.forwardQuestion { print("      \(q)") }
                for line in wrap("NEXT FLIGHT: \(v.nextFlight)", width: 78) { print("      \(line)") }
                for e in v.evidence {
                    print(String(format: "      evidence  %@ = %.4f (rule required %@)",
                                 e.measurement, e.measured, e.required))
                }
                print("      rule \(v.ruleID) — \(v.origin)")
            }
        }
        if !r.uncovered.isEmpty {
            print("")
            print("  NOT JUDGED — no rule covered \(r.uncovered.count) candidate(s): "
                  + r.uncovered.map(String.init).joined(separator: ", "))
            print("    Left unjudged rather than banded, so a thin criteria set cannot")
            print("    read as a complete verdict.")
        }
        for m in r.malformed { print("  MALFORMED VERDICT  \(m)") }
        printLessons(r)
    }

    static func printLessons(_ r: Coaching.Report) {
        for lesson in r.lessons {
            print("")
            for line in wrap(lesson.headline, width: 86) { print("  \(line)") }
            for line in wrap(lesson.detail, width: 86) { print("    \(line)") }
            print("    — \(lesson.origin)")
        }
    }

    static func printJSON(reader: VideoReader, series: LumaSeries,
                          result: EventDetector.Result, findings: [Finding],
                          coach: Coaching.Coach, coaching: Coaching.Report) {
        let i = reader.info
        var s = "{\n"
        s += "  \"walk\": \"\(Walk.version)\",\n"
        s += "  \"file\": \"\(jsonEscape(i.url.path))\",\n"
        s += "  \"video\": { \"width\": \(i.width), \"height\": \(i.height), \"codec\": \"\(i.codec)\", "
        s += "\"bitDepth\": \(i.bitDepth.map(String.init) ?? "null"), "
        s += String(format: "\"fps\": %.6f, \"seconds\": %.6f, ", i.fps, i.seconds)
        s += "\"frameDuration\": { \"value\": \(i.frameDuration.value), \"timescale\": \(i.frameDuration.timescale) }, "
        s += "\"colorPrimaries\": \(i.colorPrimaries.map { "\"\($0)\"" } ?? "null"), "
        s += "\"transferFunction\": \(i.transferFunction.map { "\"\($0)\"" } ?? "null"), "
        s += "\"yCbCrMatrix\": \(i.yCbCrMatrix.map { "\"\($0)\"" } ?? "null"), "
        s += "\"isHLGBT2020\": \(i.isHLGBT2020) },\n"
        s += "  \"workingColorSpace\": \"\(VideoReader.workingColorSpaceName)\",\n"
        // #740 DEFECTS 1 AND 2, FOR THE MACHINE READER. A model or script reading
        // this JSON has no header text to warn it, and it is the consumer most
        // likely to treat `sigma` as corroboration of `relativeRise` or to compare
        // `relativeRise` against a Y-plane figure. Both are additive string fields;
        // no existing field changed name, type or shape, so a 0.5.0 consumer is
        // unaffected.
        s += "  \"relativeRiseMeasuredIn\": \"\(VideoReader.workingColorSpaceName), pinned. This is NOT the gamma-encoded 10-bit Y plane that yMean and yMax report, and no fixed factor converts between them.\",\n"
        s += "  \"sigmaDerivation\": \"sigma = relativeRise / detector.robustSigma. robustSigma is one constant for the whole clip, so within a clip sigma is relativeRise rescaled: identical ranking, no independent information. It is for comparing across clips and is not a second measurement.\",\n"
        s += String(format: "  \"scan\": { \"framesDecoded\": %d, \"wallSeconds\": %.6f, \"framesPerSecond\": %.3f, \"ciMillisecondsPerFrame\": %.4f, \"missingIndices\": %@ },\n",
                    series.decodedFrames, series.wallSeconds, series.framesPerSecond,
                    series.ciMillisecondsPerFrame,
                    "[" + series.missingIndices.map(String.init).joined(separator: ",") + "]")
        s += String(format: "  \"detector\": { \"threshold\": %.9f, \"statisticalThreshold\": %.9f, \"floorThreshold\": %.9f, \"boundBy\": \"%@\", \"robustSigma\": %.9g, \"medianRelativeRise\": %.9g, \"framesConsidered\": %d, \"candidatesBeforeMerge\": %d, \"foundNothing\": %@ },\n",
                    result.threshold, result.statisticalThreshold, result.floorThreshold,
                    result.boundBy.rawValue, result.robustSigma, result.medianRelativeRise,
                    result.framesConsidered, result.candidatesBeforeMerge,
                    result.foundNothing ? "true" : "false")
        s += "  \"events\": [\n"
        s += findings.map { f -> String in
            let e = f.event
            var o = "    { "
            o += "\"frame\": \(e.index), \"timecode\": \"\(reader.timecode(ofFrame: e.index))\", "
            o += String(format: "\"time\": %.6f, \"ciLuma\": %.9f, \"baseline\": %.9f, \"delta\": %.9f, \"relativeRise\": %.9f, \"sigma\": %.4f, \"mergedFrames\": %d",
                        e.time, e.value, e.baseline, e.delta, e.relativeRise, e.sigma, e.mergedFrames)
            if let y = f.sample?.yMean {
                o += String(format: ", \"yMean\": %.6f", y)
                o += ", \"yMax\": \(f.sample?.yMax.map(String.init) ?? "null")"
                o += ", \"yClipped\": \(f.sample?.yClipped.map { $0 ? "true" : "false" } ?? "null")"
            }
            if let l = f.labels {
                o += ", \"vision\": { "
                o += l.requested.keys.sorted().map { String(format: "\"%@\": %.6f", $0, l.requested[$0]!) }.joined(separator: ", ")
                o += ", \"top\": [" + l.top.map { String(format: "{\"identifier\":\"%@\",\"confidence\":%.6f}", $0.identifier, $0.confidence) }.joined(separator: ",") + "]"
                o += String(format: ", \"milliseconds\": %.3f }", l.milliseconds)
            } else { o += ", \"vision\": null" }
            return o + " }"
        }.joined(separator: ",\n")
        s += "\n  ],\n"
        s += "  \"coaching\": {\n"
        s += "    \"available\": \(coaching.available),\n"
        s += "    \"headline\": \"\(jsonEscape(coaching.headline))\",\n"
        if let reason = coaching.unavailableReason {
            s += "    \"reason\": \"\(jsonEscape(reason))\",\n"
            s += "    \"searched\": [" + coaching.searched.map { "\"\(jsonEscape($0))\"" }.joined(separator: ", ") + "],\n"
        }
        s += "    \"bands\": [" + Coaching.Band.allCases.sorted { $0.order < $1.order }.map {
            "{\"band\":\"\($0.rawValue)\",\"label\":\"\($0.label)\",\"namesOneChange\":\($0.requiresChange),\"asksForwardQuestion\":\($0.requiresForwardQuestion)}"
        }.joined(separator: ",") + "],\n"
        s += "    \"verdicts\": [\n"
        s += coaching.verdicts.map { v -> String in
            var o = "      { \"band\": \"\(v.band.rawValue)\", \"frame\": \(v.frame)"
            o += ", \"reason\": \"\(jsonEscape(v.reason))\""
            o += ", \"change\": " + (v.change.map { "\"\(jsonEscape($0))\"" } ?? "null")
            o += ", \"forwardQuestion\": " + (v.forwardQuestion.map { "\"\(jsonEscape($0))\"" } ?? "null")
            o += ", \"nextFlight\": \"\(jsonEscape(v.nextFlight))\""
            o += ", \"rule\": \"\(jsonEscape(v.ruleID))\", \"origin\": \"\(jsonEscape(v.origin))\""
            o += ", \"evidence\": [" + v.evidence.map {
                String(format: "{\"measurement\":\"%@\",\"measured\":%.6f,\"required\":\"%@\",\"held\":%@}",
                       jsonEscape($0.measurement), $0.measured, jsonEscape($0.required),
                       $0.held ? "true" : "false")
            }.joined(separator: ",") + "]"
            return o + " }"
        }.joined(separator: ",\n")
        s += "\n    ],\n"
        s += "    \"uncoveredCandidateFrames\": [" + coaching.uncovered.map(String.init).joined(separator: ",") + "],\n"
        s += "    \"criteria\": " + (coach.criteria.map { c in
            "{\"version\":\"\(jsonEscape(c.header.version))\",\"walk\":\"\(jsonEscape(c.header.walk))\",\"owner\":\"\(jsonEscape(c.header.owner))\",\"source\":\"\(jsonEscape(c.source))\",\"rules\":\(c.rules.count)}"
        } ?? "null") + ",\n"
        s += "    \"lessons\": [" + coaching.lessons.map {
            "{\"id\":\"\($0.id)\",\"headline\":\"\(jsonEscape($0.headline))\",\"origin\":\"\(jsonEscape($0.origin))\"}"
        }.joined(separator: ",") + "]\n"
        s += "  },\n"
        s += "  \"note\": \"Confidences and luminance deltas are measurements, and they are the EVIDENCE UNDER the coaching verdict rather than the answer (decision #513). When coaching.available is false no band was assigned to anything and coaching.reason says why.\"\n"
        s += "}"
        print(s)
    }
}

// MARK: - walk segments

enum SegmentsCommand {

    static func run(_ argv: [String]) async {
        guard argv.count >= 3 else {
            err("""
                usage: walk segments <video> [--handles <sec>] [--lead <sec>] [--tail <sec>]
                                     [--out <dir>] [--fps <n>] [--dry-run] [--frames a-b]
                """)
        }
        let path = argv[2]
        var lead = 1.0, tail = 1.0, fps: Int32 = 30
        var outDir: String? = nil
        var dryRun = false
        var frames: Range<Int>? = nil
        var i = 3
        while i < argv.count {
            switch argv[i] {
            case "--handles": i += 1; let v = Double(argv[safe: i] ?? "") ?? 1.0; lead = v; tail = v
            case "--lead":    i += 1; lead = Double(argv[safe: i] ?? "") ?? lead
            case "--tail":    i += 1; tail = Double(argv[safe: i] ?? "") ?? tail
            case "--out":     i += 1; outDir = argv[safe: i]
            case "--fps":     i += 1; fps = Int32(argv[safe: i] ?? "") ?? fps
            case "--dry-run": dryRun = true
            case "--frames":
                i += 1
                let parts = (argv[safe: i] ?? "").split(separator: "-")
                guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), hi > lo else {
                    err("--frames wants a-b")
                }
                frames = lo..<hi
            default: err("unknown option \(argv[i])")
            }
            i += 1
        }

        do {
            let reader = try await VideoReader(url: URL(fileURLWithPath: path))
            ScanCommand.printHeader(reader.info, reader: reader)
            // THROUGH ClipScan, so this is not a third copy of the sequence.
            var opts = ClipScan.Options(frames: frames, computeYPlane: false)
            opts.classify = false
            let scanned = try await ClipScan.run(reader.url, options: opts)
            print(String(format: "scan          %d frames in %.3f s = %.1f fps",
                         scanned.decodedFrames, scanned.scanSeconds, scanned.framesPerSecond))
            print("result        \(scanned.verdict)")
            guard !scanned.candidates.isEmpty else {
                print("\nNothing to cut. No segment written.")
                return
            }

            // THE CLAMP, AND WHERE IT CAME FROM. 0.3.0 clamped against the
            // decoded frame count here. That is right for a whole clip and wrong
            // for a --frames window, where the decoded count is the size of the
            // window: it reported "tail short 0.099 s (clip offered 0.901)" on a
            // clip with 2771 frames and a full second available. See
            // ClipScan.Result.segmentClamp.
            let clamp = scanned.segmentClamp
            print("clamp         \(clamp.totalFrames) frames — \(clamp.basis)")
            let builder = SegmentBuilder(totalFrames: clamp.totalFrames,
                                         frameDuration: reader.info.frameDuration)
            let segments = builder.segments(forEventFrames: scanned.candidates.map(\.frame),
                                            leadSeconds: lead, tailSeconds: tail)
            print(String(format: "\nsegments      %d (handles requested: %.2f s lead, %.2f s tail)", segments.count, lead, tail))
            print("  #   event   frames            count   seconds   lead      tail      handles")
            for (n, s) in segments.enumerated() {
                print(String(format: "  %-3d %5d   %6d..%-6d %6d   %7.3f   %6.3f    %6.3f    %@",
                             n + 1, s.eventIndex, s.startFrame, s.endFrame, s.frameCount,
                             s.seconds, s.leadSeconds, s.tailSeconds, s.shortfallNote))
            }
            let short = segments.filter(\.isShort)
            if !short.isEmpty {
                print("\n\(short.count) of \(segments.count) segment\(short.count == 1 ? "" : "s") could not get the handles asked for.")
                print("Reported rather than clamped silently: an event 0.70 s into a clip has 0.70 s of lead-in, full stop.")
            }

            guard !dryRun else { print("\n--dry-run: nothing written."); return }
            guard let outDir else {
                print("\nNo --out directory given, so nothing was written. Add --out <dir> to cut.")
                return
            }
            let dir = URL(fileURLWithPath: outDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = VideoWriter(options: .init(targetFrameRate: fps))
            let stem = reader.info.url.deletingPathExtension().lastPathComponent
            print("")
            for (n, s) in segments.enumerated() {
                let out = dir.appendingPathComponent(String(format: "%@_seg%02d_f%06d.mov", stem, n + 1, s.eventIndex))
                do {
                    let r = try await writer.write(reader, frames: s.frames, to: out)
                    print(String(format: "  %@  %d frames -> %.4f s at %.2f fps  %@ %@bit %@  %.1f MB  %.1f fps encode",
                                 out.lastPathComponent, r.framesAppended, r.outputSeconds,
                                 r.outputFrameRate, r.codec, r.bitDepth.map(String.init) ?? "?",
                                 r.transferFunction ?? "?", Double(r.bytes) / 1e6, r.framesPerSecondEncoded))
                    print("      retime \(r.retimeRatio.numerator)/\(r.retimeRatio.denominator) — \(r.verificationNote)")
                } catch {
                    print("  \(out.lastPathComponent)  FAILED: \(error)")
                }
            }
            print("\nRe-encode path only. Passthrough is open defect task #721 — 180x faster and")
            print("silently 22 frames short with every success signal returning true.")
        } catch { err("segments failed: \(error)") }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - walk sheet

/// The third front door onto `sheet.timeSampled`, and it is here for the same
/// reason `walk scan` is: a capability reachable only through MCP is a
/// capability that cannot be run by hand when it misbehaves. Nothing below
/// measures or decodes — `ProofSheet` does all of it, and this formats.
enum SheetCommand {

    struct Args {
        var paths: [String] = []
        var out: String? = nil
        var frames = 12
        var cellWidth: Double = 900
        var recursive = false
        var placeholders = true
        var maxItems: Int? = nil
        var json = false
    }

    static func parse(_ argv: [String]) -> Args {
        guard argv.count >= 3 else {
            err("""
                usage: walk sheet <folder-or-file> [more...] [--out <dir>] [--frames <n>]
                                  [--cell-width <px>] [--recursive] [--no-placeholders]
                                  [--max-items <n>] [--json]
                """)
        }
        var a = Args()
        var i = 2
        while i < argv.count {
            switch argv[i] {
            case "--out":
                i += 1
                guard i < argv.count else { err("--out wants a directory") }
                a.out = argv[i]
            case "--frames":
                i += 1
                guard i < argv.count, let n = Int(argv[i]), n >= 1, n <= 60 else {
                    err("--frames wants a number between 1 and 60")
                }
                a.frames = n
            case "--cell-width":
                i += 1
                guard i < argv.count, let w = Double(argv[i]), w >= 64, w <= 3840 else {
                    err("--cell-width wants a number between 64 and 3840")
                }
                a.cellWidth = w
            case "--max-items":
                i += 1
                guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                    err("--max-items wants a positive number")
                }
                a.maxItems = n
            case "--recursive": a.recursive = true
            case "--no-placeholders": a.placeholders = false
            case "--json": a.json = true
            default: a.paths.append(argv[i])
            }
            i += 1
        }
        guard !a.paths.isEmpty else { err("walk sheet needs at least one folder or file") }
        return a
    }

    static func run(_ argv: [String]) async {
        let a = parse(argv)
        let inputs = a.paths.map { URL(fileURLWithPath: $0) }
        let name = inputs[0].lastPathComponent.isEmpty ? "sheet" : inputs[0].lastPathComponent
        var options = ProofSheet.Options(
            outputDirectory: a.out.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? ProofSheet.Options.defaultDirectory(name: name))
        options.framesPerClip = a.frames
        options.cellWidth = a.cellWidth
        options.recursive = a.recursive
        options.placeholders = a.placeholders
        options.maximumItems = a.maxItems

        // PROGRESS IS THE WHOLE POINT ON THIS JOB. A sheet over the operator's
        // card is tens of seconds of decoding, and a front door that prints
        // nothing until it finishes is indistinguishable from one that hung.
        let quiet = a.json
        do {
            let sheet = try await ProofSheet.run(inputs, options: options) { p in
                guard !quiet else { return }
                switch p {
                case .enumerated(let items, let cells):
                    print("found         \(items) item\(items == 1 ? "" : "s"), \(cells) cell\(cells == 1 ? "" : "s")")
                case .manifestWritten(let url):
                    print("manifest      \(url.path)")
                case .placeholder(let item, let cell, let of):
                    FileHandle.standardError.write("  placeholder item \(item + 1) cell \(cell + 1)/\(of)\r".data(using: .utf8)!)
                case .sharp(let item, let cell, let of):
                    FileHandle.standardError.write("  cell        item \(item + 1) cell \(cell + 1)/\(of)\r".data(using: .utf8)!)
                case .itemFailed(let url, let why):
                    print("UNREADABLE    \(url.lastPathComponent): \(why)")
                }
            }

            if a.json {
                let payload = ProofSheet.manifest(items: sheet.items, found: sheet.found,
                                                  inputs: inputs, options: options)
                if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                       options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: d, encoding: .utf8) {
                    print(s)
                }
                return
            }

            print("")
            print("sheet         \(sheet.directory.path)")
            print("manifest      \(sheet.manifest.path)")
            print("result        \(sheet.verdict)")
            print(String(format: "timing        metadata %.3f s, placeholders %.3f s, cells %.3f s, total %.3f s",
                         sheet.metadataSeconds, sheet.placeholderSeconds,
                         sheet.sharpSeconds, sheet.totalSeconds))
            if !sheet.found.skipped.isEmpty {
                print("skipped       \(sheet.found.skipped.count) file(s), each with a reason in the manifest")
            }
            print("")
            print("  item                                      kind   cells  dims          fps     dur      shutter")
            for item in sheet.items {
                let dims = item.width > 0 ? "\(item.width)x\(item.height)" : "-"
                let fps = item.fps.map { String(format: "%.2f", $0) } ?? "-"
                let dur = item.seconds.map { String(format: "%.1fs", $0) } ?? "-"
                var shutter = "-"
                if let s = item.shutter {
                    shutter = String(format: "1/%.0f  %+.1f stop%@ from 180deg",
                                     s.medianDenominator, s.stopsFromOneEighty,
                                     abs(s.stopsFromOneEighty) < 1.05 ? " " : "s")
                }
                let ready = item.cells.filter(\.ready).count
                print(String(format: "  %-40@  %-5@  %2d/%-2d  %-12@  %-6@  %-7@  %@",
                             String(item.url.lastPathComponent.prefix(40)),
                             item.kind.rawValue, ready, item.cells.count,
                             dims, fps, dur, shutter))
                if let e = item.error { print("      could not be read: \(e)") }
            }
            print("")
            // #513 / #499, said out loud on the one surface a person reads.
            print("This sheet DISPLAYS and MEASURES. Nothing in it is banded, ranked or scored,")
            print("and the shutter column compares each clip to the 180-degree convention")
            print("1/(2 x fps) — a measurement against a named standard, not a verdict on the")
            print("footage. The coaching verdict is `walk scan`, from a criteria file.")
        } catch {
            err("\(error)")
        }
    }
}
