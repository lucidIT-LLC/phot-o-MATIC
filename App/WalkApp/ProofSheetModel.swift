import Foundation
import SwiftUI
import CoreGraphics
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

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts"]

    /// See the comment at the scan call. 1 is exact and slow, 4 is fast and
    /// approximate, and the UI labels whichever it used.
    static let appYPlaneStride = 4

    func open(_ urls: [URL]) {
        var files = [URL]()
        let fm = FileManager.default
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let items = (try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: items.filter {
                    Self.videoExtensions.contains($0.pathExtension.lowercased())
                })
            } else if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            state = .failed("Nothing to scan — no video files in what you opened.")
            return
        }
        scan(files)
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

    /// The whole engine, in the order the CLI uses it. Nothing here is app-only:
    /// read, scan, detect, classify.
    private static func scanOne(_ url: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> ClipResult {
        let reader = try await VideoReader(url: url)
        let total = max(1, reader.info.estimatedFrameCount)
        // STRIDE 4, NOT 1, AND THE UI SAYS SO.
        //
        // Stride 1 is the known-answer path — it is what agrees with
        // ffmpeg signalstats to three decimals and what produces 439.098 on
        // frame 2347. It is also a full CPU pass over 8.3M pixels per frame:
        // MEASURED at 95 fps against 361 fps at stride 4 on this clip, 29 s
        // versus 8 s. The app takes the fast one because triage is its job, and
        // every Y figure it shows is LABELLED "stride 4" so nobody compares it
        // to a reference it was never going to match. `walk scan` uses stride 1.
        let series = try await FrameScanner.scan(
            reader, options: .init(computeYPlane: true, yPlaneStride: Self.appYPlaneStride)
        ) { index in
            if index % 60 == 0 { progress(Double(index) / Double(total)) }
        }
        let detection = EventDetector().detect(series)
        let classifier = Classifier()

        var moments = [Moment]()
        for event in detection.events {
            if Task.isCancelled { break }
            var labels = [(String, Double)]()
            var lightning = 0.0
            var thumb: CGImage? = nil
            if let frame = try? await reader.frame(at: event.index) {
                if let result = try? await classifier.classify(frame) {
                    labels = result.top.map { ($0.identifier, $0.confidence) }
                    lightning = result.confidence("lightning")
                }
                thumb = frame.makeDisplayImage(maxWidth: 560)
            }
            let sample = series.sample(at: event.index)
            moments.append(Moment(
                clip: url, frame: event.index,
                timecode: reader.timecode(ofFrame: event.index),
                time: event.time, ciLuma: event.value, baseline: event.baseline,
                relativeRise: event.relativeRise, sigma: event.sigma,
                yMean: sample?.yMean, yMax: sample?.yMax,
                yClipped: sample?.yClipped ?? false,
                mergedFrames: event.mergedFrames,
                labels: labels, lightning: lightning, thumbnail: thumb))
        }

        return ClipResult(
            url: url, info: reader.info, decodedFrames: series.decodedFrames,
            scanSeconds: series.wallSeconds, framesPerSecond: series.framesPerSecond,
            threshold: detection.threshold, boundBy: detection.boundBy.rawValue,
            statisticalThreshold: detection.statisticalThreshold,
            scaleCollapsed: detection.scaleCollapsed,
            verdict: detection.verdict, missingIndices: series.missingIndices,
            moments: moments)
    }
}
