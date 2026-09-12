import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The 0.1.0 still grade as a library call: measure, grade, measure again,
/// check for a cast it added, write the PNG.
///
/// WHY IT MOVED HERE IN 0.4.0. All of this lived in `Sources/walk/main.swift`,
/// top-level, in the CLI. The MCP front door needs the same thing, and the only
/// way to reach it was to write the sequence out a second time — a second place
/// where the colour-management flag could be forgotten, a second place where a
/// NaN baseline could be graded straight past. `#507` makes the MCP surface the
/// front door; a front door that reimplements the engine is the drift this
/// repository is built to prevent, so the engine moved instead.
///
/// The measurements are unchanged: `HLGGrade.meanRaw` before,
/// `HLGGrade.mean` after, spread delta as the cast check.
public enum StillGrade {

    public struct Report: Sendable {
        public let input: URL
        public let output: URL?
        public let lookName: String
        public let targetNits: Double
        public let systemGamma: Double
        public let width: Int
        public let height: Int
        public let before: HLGGrade.Reading
        public let after: HLGGrade.Reading
        public let milliseconds: Double

        /// Positive means the grade WIDENED the channel spread — it introduced
        /// a cast that was not in the file. The threshold is the CLI's, kept
        /// identical so the two front doors cannot disagree about a warning.
        public var castDelta: Double { after.spread - before.spread }
        public var addedCast: Bool { castDelta > 0.01 }
        public var megapixels: Double { Double(width * height) / 1e6 }

        public var castNote: String {
            addedCast
                ? String(format: "WARNING: the grade ADDED a colour cast (spread %+.4f)", castDelta)
                : String(format: "ok (spread %+.4f)", castDelta)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotRead(URL)
        case baselineNotMeasurable(URL)
        case resultNotMeasurable(URL)
        case renderFailed
        case cannotWrite(URL)

        public var description: String {
            switch self {
            case .cannotRead(let u):  return "cannot read \(u.path)"
            case .baselineNotMeasurable(let u):
                return "BASELINE MEASUREMENT FAILED (NaN) on \(u.lastPathComponent) — refusing to grade without a baseline"
            case .resultNotMeasurable(let u):
                return "RESULT MEASUREMENT FAILED (NaN) grading \(u.lastPathComponent)"
            case .renderFailed:       return "render failed"
            case .cannotWrite(let u): return "cannot write \(u.path)"
            }
        }
    }

    public static func look(named name: String, targetNits: Double) -> HLGGrade.Look {
        var l: HLGGrade.Look = (name.lowercased() == "neutral") ? .neutral : .dramatic
        l.targetNits = targetNits
        return l
    }

    /// Grade one still. `output == nil` measures and reports without writing —
    /// which is a legitimate answer to "what would this do", and cheaper than
    /// writing a file the caller then throws away.
    public static func run(input: URL, output: URL?,
                           lookName: String = "dramatic",
                           targetNits: Double = 100) throws -> Report {
        // Colour management DISABLED on load. The file holds HLG-encoded BT.2020
        // values; letting ColorSync interpret them transforms the numbers before
        // the transform runs.
        guard let image = CIImage(contentsOf: input, options: [.colorSpace: NSNull()]) else {
            throw Failure.cannotRead(input)
        }
        let look = look(named: lookName, targetNits: targetNits)

        let before = HLGGrade.meanRaw(image)
        guard before.valid else { throw Failure.baselineNotMeasurable(input) }

        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [
            .workingColorSpace: linear,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
        ])

        let t0 = DispatchTime.now().uptimeNanoseconds
        let graded = HLGGrade.apply(to: image, look: look)
        let after = HLGGrade.mean(graded, context: ctx, colorSpace: linear)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        guard after.valid else { throw Failure.resultNotMeasurable(input) }

        if let output {
            guard let cg = ctx.createCGImage(graded, from: graded.extent,
                                             format: .RGBA8, colorSpace: srgb) else {
                throw Failure.renderFailed
            }
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure.cannotWrite(output)
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(output) }
        }

        return Report(input: input, output: output, lookName: lookName,
                      targetNits: targetNits,
                      systemGamma: Double(HLGGrade.systemGamma(targetNits: targetNits)),
                      width: Int(image.extent.width), height: Int(image.extent.height),
                      before: before, after: after, milliseconds: ms)
    }
}
