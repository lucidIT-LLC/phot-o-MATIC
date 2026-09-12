import Foundation
import CoreMedia

/// Turns event frames into cut ranges with handles either side.
///
/// THE CONSTRAINT THAT MADE THIS ITS OWN TYPE. An event 0.70 s into a 16.2 s
/// clip has 0.70 s of lead-in available, not the 2 s you asked for. Clamping
/// silently is how a cut arrives short and nobody knows why, so a `Segment`
/// carries what was requested, what was available, and the shortfall.
public struct SegmentBuilder: Sendable {

    public struct Segment: Sendable {
        public let eventIndex: Int
        public let startFrame: Int
        /// Exclusive.
        public let endFrame: Int
        public let requestedLeadSeconds: Double
        public let requestedTailSeconds: Double
        public let leadSeconds: Double
        public let tailSeconds: Double
        public let frameDuration: CMTime

        public var frameCount: Int { endFrame - startFrame }
        public var seconds: Double { Double(frameCount) * CMTimeGetSeconds(frameDuration) }
        public var frames: Range<Int> { startFrame..<endFrame }
        public var leadShortfallSeconds: Double { max(0, requestedLeadSeconds - leadSeconds) }
        public var tailShortfallSeconds: Double { max(0, requestedTailSeconds - tailSeconds) }
        public var isShort: Bool { leadShortfallSeconds > 1e-9 || tailShortfallSeconds > 1e-9 }

        public var timeRange: CMTimeRange {
            CMTimeRange(start: CMTimeMultiply(frameDuration, multiplier: Int32(clamping: startFrame)),
                        duration: CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frameCount)))
        }

        /// Says what is missing and why, or that nothing is.
        public var shortfallNote: String {
            guard isShort else { return "full handles" }
            var parts = [String]()
            if leadShortfallSeconds > 1e-9 {
                parts.append(String(format: "lead short %.3f s (asked %.2f, clip offered %.3f)",
                                    leadShortfallSeconds, requestedLeadSeconds, leadSeconds))
            }
            if tailShortfallSeconds > 1e-9 {
                parts.append(String(format: "tail short %.3f s (asked %.2f, clip offered %.3f)",
                                    tailShortfallSeconds, requestedTailSeconds, tailSeconds))
            }
            return parts.joined(separator: "; ")
        }
    }

    /// Frames available in the source, used as the clamp. Pass the DECODED
    /// count where you have one.
    public var totalFrames: Int
    public var frameDuration: CMTime
    /// Merge two segments whose ranges overlap into one, so two strikes a third
    /// of a second apart do not produce two nearly identical files.
    public var coalesceOverlapping: Bool

    public init(totalFrames: Int, frameDuration: CMTime, coalesceOverlapping: Bool = true) {
        self.totalFrames = totalFrames
        self.frameDuration = frameDuration
        self.coalesceOverlapping = coalesceOverlapping
    }

    public func segments(forEventFrames eventFrames: [Int],
                         leadSeconds: Double,
                         tailSeconds: Double) -> [Segment] {
        let fd = CMTimeGetSeconds(frameDuration)
        guard fd > 0, totalFrames > 0 else { return [] }
        let leadFrames = Int((leadSeconds / fd).rounded())
        let tailFrames = Int((tailSeconds / fd).rounded())

        var built = eventFrames.sorted().map { event -> Segment in
            let start = max(0, event - leadFrames)
            let end = min(totalFrames, event + tailFrames + 1)   // +1 keeps the event frame itself
            return Segment(eventIndex: event, startFrame: start, endFrame: end,
                           requestedLeadSeconds: leadSeconds, requestedTailSeconds: tailSeconds,
                           leadSeconds: Double(event - start) * fd,
                           tailSeconds: Double(max(0, end - 1 - event)) * fd,
                           frameDuration: frameDuration)
        }

        guard coalesceOverlapping, built.count > 1 else { return built }
        var merged = [Segment]()
        for s in built {
            guard let last = merged.last, s.startFrame < last.endFrame else { merged.append(s); continue }
            // Keep the first event's identity and the union of the ranges; the
            // handles reported are those of the combined span.
            let start = last.startFrame, end = max(last.endFrame, s.endFrame)
            merged[merged.count - 1] = Segment(
                eventIndex: last.eventIndex, startFrame: start, endFrame: end,
                requestedLeadSeconds: leadSeconds, requestedTailSeconds: tailSeconds,
                leadSeconds: Double(last.eventIndex - start) * fd,
                tailSeconds: Double(max(0, end - 1 - last.eventIndex)) * fd,
                frameDuration: frameDuration)
        }
        built = merged
        return built
    }
}
