import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import WalkKit

/// One found moment, with everything measured about it and nothing judged.
struct Moment: Identifiable {
    let id = UUID()
    let clip: URL
    let frame: Int
    let timecode: String
    let time: Double
    let ciLuma: Double
    let baseline: Double
    let relativeRise: Double
    let sigma: Double
    let yMean: Double?
    let yMax: Int?
    let yClipped: Bool
    let mergedFrames: Int
    let labels: [(String, Double)]
    let lightning: Double
    var thumbnail: CGImage?
}

struct ClipResult: Identifiable {
    let id = UUID()
    let url: URL
    let info: VideoInfo
    let decodedFrames: Int
    let scanSeconds: Double
    let framesPerSecond: Double
    let threshold: Double
    let boundBy: String
    let statisticalThreshold: Double
    let scaleCollapsed: Bool
    let verdict: String
    let missingIndices: [Int]
    var moments: [Moment]
}

@MainActor
@Observable
final class ProofSheetModel {

    enum State: Equatable {
        case idle
        case scanning(clip: String, progress: Double)
        case done
        case failed(String)
    }

    var state: State = .idle
    var clips: [ClipResult] = []
    var selectedClip: ClipResult.ID?
    var selectedMoment: Moment.ID?
    /// Every candidate is shown by default. This filter is the operator's to
    /// move, and it starts at zero so nothing is hidden until he hides it.
    var minimumLightning: Double = 0.0
    private var scanTask: Task<Void, Never>?

    var currentClip: ClipResult? {
        clips.first { $0.id == selectedClip } ?? clips.first
    }

    var visibleMoments: [Moment] {
        (currentClip?.moments ?? []).filter { $0.lightning >= minimumLightning }
    }

    var moment: Moment? {
        visibleMoments.first { $0.id == selectedMoment }
    }

    /// See the comment at the scan call. 1 is exact and slow, 4 is fast and
    /// approximate, and the UI labels whichever it used.
    static let appYPlaneStride = 4

    /// THE FOLDER WALK LEFT THIS FILE IN 0.4.0, AND THAT WAS THE POINT.
    ///
    /// This method used to hold its own `contentsOfDirectory` call and its own
    /// private `videoExtensions` set. That is how the operator dropped a folder
    /// in, watched the app walk eight clips, and found `ingest.dump` sitting in
    /// `Walk.notImplemented` the whole time — decision #507, contract drift
    /// inside the version contract. The app was doing something the library did
    /// not declare because the app had quietly implemented it.
    ///
    /// `ClipFinder` now owns it, `ingest.folderScan` declares it, and it has
    /// tests. The app is a front door again.
    func open(_ urls: [URL]) {
        let found = ClipFinder.find(urls)
        guard !found.clips.isEmpty else {
            state = .failed("Nothing to scan — \(found.verdict)")
            return
        }
        scan(found.clips)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        state = .done
    }

    private func scan(_ files: [URL]) {
        scanTask?.cancel()
        clips = []
        selectedClip = nil
        selectedMoment = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            for file in files {
                if Task.isCancelled { break }
                self.state = .scanning(clip: file.lastPathComponent, progress: 0)
                do {
                    let result = try await Self.scanOne(file) { fraction in
                        Task { @MainActor in
                            self.state = .scanning(clip: file.lastPathComponent, progress: fraction)
                        }
                    }
                    if Task.isCancelled { break }
                    self.clips.append(result)
                    if self.selectedClip == nil { self.selectedClip = result.id }
                } catch {
                    self.state = .failed("\(file.lastPathComponent): \(error)")
                    return
                }
            }
            self.state = .done
            self.scanTask = nil
        }
    }

    /// One clip, through the library's own orchestration.
    ///
    /// This was a hand-written copy of `read, scan, detect, classify` — the same
    /// sequence the CLI had and the MCP server would have needed a third time.
    /// Three copies of an order of operations is how a front door drifts from
    /// the library it fronts, so the sequence moved to `ClipScan` and this calls
    /// it. No number here changed.
    private static func scanOne(_ url: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> ClipResult {
        // STRIDE 4, NOT 1, AND THE UI SAYS SO.
        //
        // Stride 1 is the known-answer path — it is what agrees with
        // ffmpeg signalstats to three decimals and what produces 439.098 on
        // frame 2347. It is also a full CPU pass over 8.3M pixels per frame:
        // MEASURED at 95 fps against 361 fps at stride 4 on this clip, 29 s
        // versus 8 s. The app takes the fast one because triage is its job, and
        // every Y figure it shows is LABELLED "stride 4" so nobody compares it
        // to a reference it was never going to match. `walk scan` uses stride 1.
        var options = ClipScan.Options.triage(
            thumbnailDirectory: ClipScan.defaultThumbnailDirectory())
        options.yPlaneStride = Self.appYPlaneStride

        // The frame count is needed for the progress fraction, and reading the
        // header is cheap next to the scan it precedes.
        let total = max(1, try await VideoReader(url: url).info.estimatedFrameCount)
        let scanned = try await ClipScan.run(url, options: options) { index in
            if index % 60 == 0 { progress(Double(index) / Double(total)) }
        }

        let moments = scanned.candidates.map { c in
            Moment(clip: url, frame: c.frame, timecode: c.timecode, time: c.time,
                   ciLuma: c.ciLuma, baseline: c.baseline, relativeRise: c.relativeRise,
                   sigma: c.sigma, yMean: c.yMean, yMax: c.yMax, yClipped: c.yClipped,
                   mergedFrames: c.mergedFrames,
                   labels: c.topLabels.map { ($0.identifier, $0.confidence) },
                   lightning: c.confidence("lightning") ?? 0,
                   thumbnail: c.thumbnail.flatMap(Self.loadThumbnail))
        }

        return ClipResult(
            url: url, info: scanned.info, decodedFrames: scanned.decodedFrames,
            scanSeconds: scanned.scanSeconds, framesPerSecond: scanned.framesPerSecond,
            threshold: scanned.detection.threshold,
            boundBy: scanned.detection.boundBy.rawValue,
            statisticalThreshold: scanned.detection.statisticalThreshold,
            scaleCollapsed: scanned.detection.scaleCollapsed,
            verdict: scanned.verdict, missingIndices: scanned.missingIndices,
            moments: moments)
    }

    /// `ClipScan` writes the display PNG to disk — one path, shared with the MCP
    /// server, which needs a file it can hand back rather than bytes in memory.
    /// The app reads it straight back for display.
    private static func loadThumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

}
