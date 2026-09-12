import Foundation
import CoreVideo
import Vision

/// Vision's built-in image classifier, run on a candidate frame.
///
/// MEASURED, decision #495 and re-measured 2026-09-12 on the current API:
/// `ClassifyImageRequest` ships a 1303-identifier taxonomy that already contains
/// `lightning`, `thunderstorm` and `storm`. No model file, no training, and no
/// app bundle — `Bundle.main.bundleIdentifier` is nil in the CLI and Vision works
/// anyway. On clip 0012, frame 2347 returns lightning 0.3435 and frame 2348
/// returns 0.0129: a 27x separation for nothing.
///
/// WHAT THE CONFIDENCE IS NOT. It is a number to report, not a verdict. Walk
/// sorts and flags; it never decides that a frame is or is not worth keeping.
public struct Classifier: Sendable {

    public struct Label: Sendable, Comparable {
        public let identifier: String
        public let confidence: Double
        public static func < (a: Label, b: Label) -> Bool { a.confidence < b.confidence }
    }

    public struct Result: Sendable {
        public let top: [Label]
        /// Confidences for the identifiers the caller asked about, present or 0.
        public let requested: [String: Double]
        public let milliseconds: Double
        public func confidence(_ identifier: String) -> Double { requested[identifier] ?? 0 }
    }

    /// Identifiers Walk asks about by default. Storm work is the material this
    /// was measured on; a caller with different subjects passes its own.
    public static let stormIdentifiers = ["lightning", "thunderstorm", "storm"]

    public var identifiers: [String]
    public var topCount: Int

    public init(identifiers: [String] = Classifier.stormIdentifiers, topCount: Int = 5) {
        self.identifiers = identifiers
        self.topCount = topCount
    }

    /// The taxonomy Vision will actually answer from. Read at runtime rather
    /// than trusted from a page — decision #490 caught Apple's published filter
    /// defaults wrong twice, and #495 caught a third and fourth contradiction.
    public static func supportedIdentifiers() -> [String] {
        ClassifyImageRequest().supportedIdentifiers
    }

    public func classify(_ frame: Frame) async throws -> Result {
        // Vision's modern async API takes a CVPixelBuffer, and a CVPixelBuffer
        // cannot be carried out of Frame.withPixelBuffer (its result is
        // `sending` and CVPixelBuffer is not Sendable). So take an owned copy,
        // which never crosses an isolation boundary, and classify that.
        guard let owned = frame.detachedCopy() else { throw WalkVideoError.pixelBufferAllocationFailed }
        return try await classify(pixelBuffer: owned)
    }

    public func classify(pixelBuffer: CVPixelBuffer) async throws -> Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let observations = try await ClassifyImageRequest().perform(on: pixelBuffer)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let sorted = observations
            .map { Label(identifier: $0.identifier, confidence: Double($0.confidence)) }
            .sorted(by: >)
        var wanted = [String: Double]()
        for id in identifiers {
            wanted[id] = sorted.first { $0.identifier == id }?.confidence ?? 0
        }
        return Result(top: Array(sorted.prefix(topCount)), requested: wanted, milliseconds: ms)
    }
}
