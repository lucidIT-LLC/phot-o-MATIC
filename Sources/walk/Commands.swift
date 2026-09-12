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
        print("working space \(VideoReader.workingColorSpaceName)  (pinned; the CIContext default is ExtendedLinearSRGB and measures 4.2x less of the event)")
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
