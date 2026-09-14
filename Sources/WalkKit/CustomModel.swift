import Foundation
import CoreML
import CoreVideo
import Vision

/// A custom Core ML model, loaded from a file and run over a frame.
///
/// WHY THIS EXISTS AND WHAT IT IS NOT. `Classifier` runs Vision's BUILT-IN
/// taxonomy — 1303 identifiers, no model file, and it already covers the storm
/// case #493 wanted Core ML for. This type is the other half: a model the
/// operator supplies, loaded at runtime from a path. It ships no model, names no
/// subjects and encodes no taxonomy, because what Walk should classify is the
/// operator's and Andy's call and decision #507 records that scoping as NOT
/// DONE. Wiring the path is an engineering question; choosing the labels is not,
/// and this file deliberately answers only the first.
///
/// MEASURED 2026-09-12, and the measurement is the reason the contract entry can
/// move. `MLModel.compileModel(at:)` is a RUNTIME api in CoreML.framework, which
/// is part of the OS and not part of Xcode: a custom `.mlmodel` compiles in
/// milliseconds and loads through `MLModel(contentsOf:)` and `VNCoreMLModel`
/// from a plain SwiftPM binary — no Xcode project, no app bundle, no signing.
/// That keeps Walk's build constraint from #490 and #495 intact.
///
/// THE OLD CONTRACT ENTRY SAID THIS WAS A CHOICE, NOT A BLOCKER, and it was
/// right. It also said the capability must not move "off the back of a spike,
/// with no code and no test behind it." This file and `CustomModelTests` are
/// that code and that test; the spike is not the evidence, these are.
/// NOT `Sendable`, DELIBERATELY. It holds a loaded `VNCoreMLModel`, and Vision
/// does not declare that type `Sendable` (checked against the SDK 27.0 header,
/// not assumed). Marking this struct `Sendable` anyway would be asserting a
/// guarantee the framework does not make — so it stays in one isolation domain
/// and the compiler enforces it. `Classifier` IS `Sendable` because it stores
/// only value types and builds its request per call; this one loads once and
/// keeps the model, which is the whole point of a custom model path.
public struct CustomModel {

    public enum Failure: Error, CustomStringConvertible {
        case notFound(URL)
        case unsupportedExtension(String)
        case compileFailed(URL, underlying: String)
        case loadFailed(URL, underlying: String)
        /// Vision refuses models it cannot drive — anything whose input is not
        /// an image. Reported rather than worked around: a model Vision will not
        /// take is not a model Walk can run over a frame.
        case notAVisionModel(URL, underlying: String)
        case noClassifications

        public var description: String {
            switch self {
            case .notFound(let u):
                return "no model file at \(u.path)"
            case .unsupportedExtension(let e):
                return "\(e.isEmpty ? "<none>" : e) is not a Core ML model extension; expected .mlmodel, .mlpackage or .mlmodelc"
            case .compileFailed(let u, let e):
                return "MLModel.compileModel refused \(u.lastPathComponent): \(e)"
            case .loadFailed(let u, let e):
                return "MLModel refused to load \(u.lastPathComponent): \(e)"
            case .notAVisionModel(let u, let e):
                return "VNCoreMLModel refused \(u.lastPathComponent) — it is probably not an image model: \(e)"
            case .noClassifications:
                return "the model ran but returned no classification observations; it is not a classifier"
            }
        }
    }

    /// What the model says about one frame, in the shape `Classifier.Result`
    /// already uses, so a criteria rule (#499) reads a custom model's output the
    /// same way it reads Vision's.
    public struct Result: Sendable {
        public let top: [Classifier.Label]
        public let milliseconds: Double
        public func confidence(_ identifier: String) -> Double {
            top.first { $0.identifier == identifier }?.confidence ?? 0
        }
        public var best: Classifier.Label? { top.first }
    }

    public let source: URL
    public let compiled: URL
    /// True when this load compiled the source rather than being handed an
    /// already-compiled `.mlmodelc`. Reported because the cost differs and a
    /// caller measuring startup should not have to infer it.
    public let didCompile: Bool
    public let compileMilliseconds: Double
    /// The labels the model can actually emit, read off the loaded model rather
    /// than trusted from a document — the same discipline `Classifier`
    /// applies to Vision's taxonomy, and for the same reason.
    public let classLabels: [String]

    private let vnModel: VNCoreMLModel

    private static let sourceExtensions: Set<String> = ["mlmodel", "mlpackage"]
    private static let compiledExtension = "mlmodelc"

    /// Load a model, compiling it first when it is not already compiled.
    ///
    /// `compileModel(at:)` writes the `.mlmodelc` into a temporary directory the
    /// OS owns and may reclaim. A caller that wants it kept passes
    /// `keepCompiledAt:` and gets a stable path back in `compiled`.
    public init(contentsOf url: URL, keepCompiledAt destination: URL? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw Failure.notFound(url) }

        let ext = url.pathExtension.lowercased()
        let t0 = DispatchTime.now().uptimeNanoseconds
        var compiledURL: URL
        var compiledHere: Bool

        if ext == Self.compiledExtension {
            compiledURL = url
            compiledHere = false
        } else if Self.sourceExtensions.contains(ext) {
            do {
                compiledURL = try MLModel.compileModel(at: url)
            } catch {
                throw Failure.compileFailed(url, underlying: String(describing: error))
            }
            compiledHere = true
        } else {
            throw Failure.unsupportedExtension(ext)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

        if compiledHere, let destination {
            // Replace rather than merge: a stale .mlmodelc left beside a new one
            // is the same silent-staleness defect the version contract exists
            // to catch.
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: compiledURL, to: destination)
            compiledURL = destination
        }

        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            throw Failure.loadFailed(url, underlying: String(describing: error))
        }
        do {
            self.vnModel = try VNCoreMLModel(for: model)
        } catch {
            throw Failure.notAVisionModel(url, underlying: String(describing: error))
        }

        self.source = url
        self.compiled = compiledURL
        self.didCompile = compiledHere
        self.compileMilliseconds = ms
        self.classLabels = (model.modelDescription.classLabels ?? []).map { "\($0)" }
    }

    public func classify(_ frame: Frame) throws -> Result {
        guard let owned = frame.detachedCopy() else {
            throw WalkVideoError.pixelBufferAllocationFailed
        }
        return try classify(pixelBuffer: owned)
    }

    /// SYNCHRONOUS, and that is not an oversight. `VNImageRequestHandler.perform`
    /// blocks until the request completes, so wrapping it in a continuation
    /// would add an isolation hop and buy nothing. `Classifier` is async because
    /// Vision's *modern* `ClassifyImageRequest.perform(on:)` genuinely is;
    /// `VNCoreMLRequest` is the classic API and is not.
    public func classify(pixelBuffer: CVPixelBuffer) throws -> Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let request = VNCoreMLRequest(model: vnModel)
        // Centre-crop is Vision's default and it silently discards the edges of
        // a 16:9 frame. `scaleFill` keeps the whole frame in view; a detector
        // that cannot see the left edge is how #498's strike at column 0 would
        // be lost again.
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

        let labels = (request.results ?? [])
            .compactMap { $0 as? VNClassificationObservation }
            .map { Classifier.Label(identifier: $0.identifier, confidence: Double($0.confidence)) }
            .sorted(by: >)
        guard !labels.isEmpty else { throw Failure.noClassifications }
        return Result(top: labels, milliseconds: ms)
    }
}
