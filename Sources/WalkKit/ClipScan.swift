import Foundation
import CoreGraphics

/// One clip, end to end: read it, measure every frame, detect candidates,
/// classify them, and optionally write a picture of each.
///
/// WHY THIS TYPE EXISTS. At 0.3.0 this sequence was written out THREE times —
/// in `ScanCommand.run`, in `ProofSheetModel.scanOne`, and it would have been a
/// fourth time in the MCP server. Three copies of an orchestration is how the
/// app came to walk folders that the library did not declare (#507). The engine
/// was never duplicated; the ORDER the engine is used in was, and that turned
/// out to be enough to drift.
///
/// Nothing here is new measurement. Every number comes from `FrameScanner`,
/// `EventDetector` and `Classifier` exactly as before.
public struct ClipScan: Sendable {

    public struct Options: Sendable {
        /// `nil` scans the whole clip.
        public var frames: Range<Int>?
        /// Run the 10-bit Y-plane pass alongside the Core Image mean.
        public var computeYPlane: Bool
        /// Y-plane sub-sampling. 1 IS THE KNOWN-ANSWER PATH — it is what agrees
        /// with `ffmpeg signalstats` to three decimals and what produces 439.098
        /// on clip 0012 frame 2347. MEASURED cost: 95 fps at stride 1 against
        /// 361 fps at stride 4 on that clip, 29 s against 8 s. A caller that
        /// takes the fast one must say so wherever it prints a Y figure.
        public var yPlaneStride: Int
        /// Ask Vision about each candidate. Off makes a scan meaningfully
        /// faster and removes the only signal that finds a thin distant bolt
        /// (#504) — a real trade, not a cosmetic one.
        public var classify: Bool
        /// Identifiers to report confidences for.
        public var identifiers: [String]
        /// Detector tuning. Defaults are `EventDetector.Options()`.
        public var detector: EventDetector.Options
        /// Where to write one display PNG per candidate. `nil` writes none.
        public var thumbnailDirectory: URL?
        public var thumbnailMaxWidth: CGFloat

        public init(frames: Range<Int>? = nil,
                    computeYPlane: Bool = true,
                    yPlaneStride: Int = 1,
                    classify: Bool = true,
                    identifiers: [String] = Classifier.stormIdentifiers,
                    detector: EventDetector.Options = EventDetector.Options(),
                    thumbnailDirectory: URL? = nil,
                    thumbnailMaxWidth: CGFloat = 640) {
            self.frames = frames
            self.computeYPlane = computeYPlane
            self.yPlaneStride = yPlaneStride
            self.classify = classify
            self.identifiers = identifiers
            self.detector = detector
            self.thumbnailDirectory = thumbnailDirectory
            self.thumbnailMaxWidth = thumbnailMaxWidth
        }

        /// The app's and the MCP server's default: fast triage, Y figures
        /// labelled as approximate wherever they are shown.
        public static func triage(thumbnailDirectory: URL? = nil) -> Options {
            Options(computeYPlane: true, yPlaneStride: 4,
                    thumbnailDirectory: thumbnailDirectory)
        }
    }

    /// One candidate with everything measured about it. Judgment is a separate
    /// pass — `Coaching.Coach` reads these values and bands them from the
    /// criteria file — so the measurement stays deterministic and the judgment
    /// stays pluggable, which is #494's seam.
    public struct Candidate: Sendable {
        public let frame: Int
        public let timecode: String
        public let time: Double
        public let ciLuma: Double
        public let baseline: Double
        public let delta: Double
        public let relativeRise: Double
        public let sigma: Double
        public let mergedFrames: Int
        public let yMean: Double?
        public let yMax: Int?
        public let yClipped: Bool
        /// Confidences for the identifiers that were asked about. `nil` when
        /// classification was off — which is NOT the same as zero, and is
        /// carried as an optional for exactly that reason.
        public let confidences: [String: Double]?
        public let topLabels: [(identifier: String, confidence: Double)]
        public let classifyMilliseconds: Double?
        /// Where the display PNG landed, if one was asked for and succeeded.
        public let thumbnail: URL?
        /// Every per-candidate stage that was ASKED FOR and failed, with the
        /// reason (task #1013 P3). Without it a classifier failure left
        /// `confidences` nil, which is exactly what "classification was off"
        /// looks like — a failure indistinguishable from a choice.
        public let failures: [StageFailure]

        public func confidence(_ identifier: String) -> Double? { confidences?[identifier] }

        /// PUBLIC so a caller that measured a clip its own way — the CLI's scan
        /// path, which builds findings rather than candidates — can hand the
        /// same values to the coach. Without it the CLI would have had to grow
        /// its own banding, and a second implementation of the judgment layer is
        /// the drift that #507 already cost this repository once.
        public init(frame: Int, timecode: String, time: Double, ciLuma: Double,
                    baseline: Double, delta: Double, relativeRise: Double,
                    sigma: Double, mergedFrames: Int, yMean: Double?, yMax: Int?,
                    yClipped: Bool, confidences: [String: Double]?,
                    topLabels: [(identifier: String, confidence: Double)],
                    classifyMilliseconds: Double?, thumbnail: URL?,
                    failures: [StageFailure] = []) {
            self.frame = frame; self.timecode = timecode; self.time = time
            self.ciLuma = ciLuma; self.baseline = baseline; self.delta = delta
            self.relativeRise = relativeRise; self.sigma = sigma
            self.mergedFrames = mergedFrames; self.yMean = yMean; self.yMax = yMax
            self.yClipped = yClipped; self.confidences = confidences
            self.topLabels = topLabels; self.classifyMilliseconds = classifyMilliseconds
            self.thumbnail = thumbnail
            self.failures = failures
        }
    }

    /// A per-candidate stage that was requested and did not complete.
    public struct StageFailure: Sendable, Equatable {
        public enum Stage: String, Sendable {
            /// The candidate frame could not be decoded, so neither the
            /// classifier nor the thumbnail had anything to work on.
            case decode
            case classify
            case thumbnail
        }
        public let stage: Stage
        public let reason: String
        public init(stage: Stage, reason: String) { self.stage = stage; self.reason = reason }
    }

    /// What the per-candidate pass produced for one frame.
    public struct Probe: Sendable {
        public let labels: Classifier.Result?
        public let thumbnail: URL?
        public let failures: [StageFailure]
    }

    /// Decode one candidate frame ONCE and hand it to the classifier and the
    /// thumbnail writer, recording every requested stage that fails.
    ///
    /// ONE implementation, used by `run` and by the CLI's own scan path. The
    /// CLI used to repeat this sequence with every step wrapped in `try?`
    /// (task #1013 P3), so a decode or classifier failure printed as `-` —
    /// the same mark as `--no-vision`.
    public static func probe(_ reader: VideoReader, frame index: Int,
                             classifier: Classifier?, thumbnailTo out: URL?,
                             thumbnailMaxWidth: CGFloat = 640) async -> Probe {
        guard classifier != nil || out != nil else {
            return Probe(labels: nil, thumbnail: nil, failures: [])
        }
        let frame: Frame
        do {
            frame = try await reader.frame(at: index)
        } catch {
            return Probe(labels: nil, thumbnail: nil,
                         failures: [StageFailure(stage: .decode, reason: "\(error)")])
        }
        var labels: Classifier.Result? = nil
        var thumb: URL? = nil
        var failures = [StageFailure]()
        if let classifier {
            do { labels = try await classifier.classify(frame) }
            catch { failures.append(StageFailure(stage: .classify, reason: "\(error)")) }
        }
        if let out {
            do { thumb = try frame.writeDisplayPNG(to: out, maxWidth: thumbnailMaxWidth) }
            catch { failures.append(StageFailure(stage: .thumbnail, reason: "\(error)")) }
        }
        return Probe(labels: labels, thumbnail: thumb, failures: failures)
    }

    public struct Result: Sendable {
        public let url: URL
        public let info: VideoInfo
        /// The frame range the caller asked for, `nil` when the whole clip was
        /// scanned. Carried because it changes what `decodedFrames` MEANS, and
        /// the difference was measurable — see `segmentClamp`.
        public let requestedFrames: Range<Int>?
        public let decodedFrames: Int
        public let scanSeconds: Double
        public let framesPerSecond: Double
        public let ciMillisecondsPerFrame: Double
        public let missingIndices: [Int]
        public let yPlaneStride: Int
        public let classified: Bool
        public let detection: EventDetector.Result
        public let candidates: [Candidate]

        public var foundNothing: Bool { candidates.isEmpty }
        /// True in both directions — see `EventDetector.Result.verdict`.
        public var verdict: String { detection.verdict }

        /// How many frames a segment builder may clamp against, and whether
        /// that figure was MEASURED or read off the container.
        ///
        /// THIS EXISTS BECAUSE THE OBVIOUS ANSWER PRODUCED A FALSE SHORTFALL,
        /// caught by reading back a real segment rather than by reasoning.
        ///
        /// 0.3.0's CLI clamped against the decoded frame count, with a comment
        /// saying so — correct, and the container estimate can be wrong. But
        /// when a SUB-RANGE is scanned, the decoded count is the size of the
        /// WINDOW and says nothing about the clip. MEASURED 2026-09-12: scanning
        /// clip 0012 frames 2300–2400 and asking for one-second handles reported
        /// "tail short 0.099 s (asked 1.00, clip offered 0.901)". The clip has
        /// ~2771 frames; a full second after frame 2388 is entirely available.
        /// The shortfall was an artefact of the scan window, attributed to the
        /// clip.
        ///
        /// A shortfall report that misnames its own cause is worse than no
        /// report, because the whole reason `SegmentBuilder` carries a shortfall
        /// is so that a short cut can be explained. So the basis is chosen by
        /// what was actually scanned, and it SAYS WHICH.
        public var segmentClamp: (totalFrames: Int, measured: Bool, basis: String) {
            let lastDecoded = (candidates.map(\.frame).max() ?? 0) + 1
            if requestedFrames == nil, decodedFrames > 0 {
                // Whole clip: the decoded count is a measurement and beats the
                // container's arithmetic.
                return (Swift.max(decodedFrames, lastDecoded), true,
                        "measured — \(decodedFrames) frames decoded over the whole clip")
            }
            // Sub-range: the window's size is not the clip's length, so the
            // container estimate is the only figure available. Named as an
            // estimate so a shortfall built on it can be read for what it is.
            return (Swift.max(info.estimatedFrameCount, lastDecoded), false,
                    "container estimate — only frames \(requestedFrames.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "?") were decoded, so the decoded count is the window and not the clip")
        }
    }

    /// Scan one clip. `progress` is called with decoded frame indices.
    public static func run(_ url: URL, options: Options = Options(),
                           progress: (@Sendable (Int) -> Void)? = nil) async throws -> Result {
        let reader = try await VideoReader(url: url)
        var scanOptions = FrameScanner.Options(frames: options.frames,
                                               computeYPlane: options.computeYPlane)
        scanOptions.yPlaneStride = options.yPlaneStride
        let series = try await FrameScanner.scan(reader, options: scanOptions, progress: progress)
        let detection = EventDetector(options: options.detector).detect(series)

        let classifier = Classifier(identifiers: options.identifiers)
        let stem = url.deletingPathExtension().lastPathComponent
        var candidates = [Candidate]()
        candidates.reserveCapacity(detection.events.count)

        for event in detection.events {
            try Task.checkCancellation()
            // ONE decode of the candidate frame serves both the classifier and
            // the picture. Decoding it twice was the obvious shape and is 0.125 s
            // of cold seek each time (#495). Failures are recorded, not dropped.
            let out = options.thumbnailDirectory.map {
                $0.appendingPathComponent(String(format: "%@_f%06d.png", stem, event.index))
            }
            let probe = await probe(reader, frame: event.index,
                                    classifier: options.classify ? classifier : nil,
                                    thumbnailTo: out,
                                    thumbnailMaxWidth: options.thumbnailMaxWidth)
            let confidences = probe.labels?.requested
            let top = probe.labels?.top.map { (identifier: $0.identifier, confidence: $0.confidence) } ?? []

            let sample = series.sample(at: event.index)
            candidates.append(Candidate(
                frame: event.index,
                timecode: reader.timecode(ofFrame: event.index),
                time: event.time, ciLuma: event.value, baseline: event.baseline,
                delta: event.delta, relativeRise: event.relativeRise, sigma: event.sigma,
                mergedFrames: event.mergedFrames,
                yMean: sample?.yMean, yMax: sample?.yMax, yClipped: sample?.yClipped ?? false,
                confidences: confidences, topLabels: top,
                classifyMilliseconds: probe.labels?.milliseconds,
                thumbnail: probe.thumbnail, failures: probe.failures))
        }

        return Result(url: url, info: reader.info, requestedFrames: options.frames,
                      decodedFrames: series.decodedFrames,
                      scanSeconds: series.wallSeconds, framesPerSecond: series.framesPerSecond,
                      ciMillisecondsPerFrame: series.ciMillisecondsPerFrame,
                      missingIndices: series.missingIndices,
                      yPlaneStride: options.yPlaneStride, classified: options.classify,
                      detection: detection, candidates: candidates)
    }

    /// Where display PNGs go when a caller does not name a directory. A cache
    /// directory, not a temp one: the host reads these back by path after the
    /// call returns, and a temp sweep between the answer and the read would look
    /// exactly like a broken thumbnail.
    public static func defaultThumbnailDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Walk/thumbnails", isDirectory: true)
    }
}

// MARK: - A folder of clips

extension ClipScan {

    public struct FolderResult: Sendable {
        public let inputs: [URL]
        public let found: ClipFinder.Found
        public let clips: [Result]
        /// Clips that could not be read at all, with the reason.
        public let failures: [(url: URL, reason: String)]

        public var totalCandidates: Int { clips.reduce(0) { $0 + $1.candidates.count } }
        public var totalFramesScanned: Int { clips.reduce(0) { $0 + $1.decodedFrames } }
        public var clipsWithNothing: [Result] { clips.filter(\.foundNothing) }

        /// The honest-empty case for a whole folder, and it has two shapes that
        /// must not be confused: nothing to scan, and nothing found. #507
        /// recorded the second one running on real material for the first time.
        public var verdict: String {
            if clips.isEmpty && failures.isEmpty { return found.verdict }
            var s = "\(clips.count) clip\(clips.count == 1 ? "" : "s") scanned, "
                + "\(totalFramesScanned) frames, \(totalCandidates) candidate\(totalCandidates == 1 ? "" : "s")"
            let empty = clipsWithNothing.count
            if empty > 0 {
                s += " — \(empty) clip\(empty == 1 ? "" : "s") returned nothing, which is an answer and not a failure"
            }
            if !failures.isEmpty { s += "; \(failures.count) could not be read" }
            if !found.unreadable.isEmpty {
                s += "; \(found.unreadable.count) location\(found.unreadable.count == 1 ? "" : "s") could not be listed — see unreadable for why"
            }
            return s
        }
    }

    /// Walk everything given and scan every clip in it.
    ///
    /// This is `ingest.folderScan`, and the name is narrow on purpose: it
    /// enumerates and scans. It does not rank, and `ingest.dump` stays in
    /// `Walk.notImplemented` until something does.
    public static func folder(_ inputs: [URL],
                              find: ClipFinder.Options = ClipFinder.Options(),
                              options: Options = Options.triage(),
                              onClipStart: (@Sendable (URL, Int, Int) -> Void)? = nil,
                              progress: (@Sendable (Int) -> Void)? = nil) async throws -> FolderResult {
        let found = ClipFinder.find(inputs, options: find)
        var results = [Result]()
        var failures = [(url: URL, reason: String)]()
        for (n, clip) in found.clips.enumerated() {
            try Task.checkCancellation()
            onClipStart?(clip, n, found.clips.count)
            do {
                results.append(try await run(clip, options: options, progress: progress))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // ONE unreadable clip does not end the walk. A folder scan that
                // aborts on the first odd file gives back nothing and explains
                // nothing, which is the failure mode this library keeps naming.
                failures.append((url: clip, reason: "\(error)"))
            }
        }
        return FolderResult(inputs: inputs, found: found, clips: results, failures: failures)
    }
}
