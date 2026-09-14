import Testing
import Foundation
import CoreVideo
import CoreGraphics
@testable import WalkKit

// THE CUSTOM CORE ML PATH, WITH A MODEL THAT HAS A KNOWN ANSWER.
//
// The fixture is deliberately trivial: two classes, `red` and `blue`, trained by
// CreateML on flat colour tiles (regenerate it with
// `Tools/make-known-answer-model.swift`). It is 16 KB because it references the
// OS feature extractor instead of embedding one, so it can live in the
// repository and run in CI with no external volume — unlike `KnownAnswerTests`,
// which needs 780 MB of the operator's archive and skips when it is absent.
//
// IT IS A FIXTURE AND NOT A TAXONOMY. What Walk should actually classify is the
// operator's and Andy's call, and decision #507 records that scoping as not
// done. These tests prove the PATH — compile, load, run, refuse — and claim
// nothing about subjects.
//
// AND THEY PROVE IT CAN FAIL. Three of the six assert refusals: a missing file,
// a file that is not a model, and bytes that are not a model at all. A load path
// that has only ever succeeded is not evidence that it checks anything.

private enum Fixture {
    /// `subdirectory:` because Package.swift declares the fixtures with `.copy`,
    /// which preserves the folder. `.process` would have compiled the model at
    /// BUILD time and left no `.mlmodel` here to compile at RUN time.
    static var model: URL? {
        Bundle.module.url(forResource: "WalkKnownAnswer", withExtension: "mlmodel",
                          subdirectory: "Fixtures")
    }

    /// A solid-colour BGRA frame, the same shape the fixture was trained on.
    static func tile(r: Double, g: Double, b: Double, side: Int = 96) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<side {
            for x in 0..<side {
                let p = base + y * stride + x * 4
                p[0] = UInt8(b * 255); p[1] = UInt8(g * 255)
                p[2] = UInt8(r * 255); p[3] = 255
            }
        }
        return buffer
    }
}

@Test func customModelCompilesAndLoadsWithoutXcode() throws {
    let url = try #require(Fixture.model, "fixture model missing from the test bundle")
    let m = try CustomModel(contentsOf: url)
    #expect(m.didCompile, ".mlmodel source must be compiled, not loaded directly")
    #expect(m.compiled.pathExtension == "mlmodelc")
    // Read the labels off the loaded model rather than asserting what we think
    // we trained — the same reason Classifier reads Vision's taxonomy at runtime.
    #expect(Set(m.classLabels) == ["red", "blue"],
            "fixture should expose exactly its two trained labels, got \(m.classLabels)")
}

@Test func customModelReturnsTheKnownAnswer() throws {
    let url = try #require(Fixture.model)
    let m = try CustomModel(contentsOf: url)

    let red = try m.classify(pixelBuffer: Fixture.tile(r: 1.0, g: 0.15, b: 0.15))
    let blue = try m.classify(pixelBuffer: Fixture.tile(r: 0.15, g: 0.15, b: 1.0))

    #expect(red.best?.identifier == "red", "got \(red.top)")
    #expect(blue.best?.identifier == "blue", "got \(blue.top)")
    // Confidences must be a distribution, not a constant — a model answering the
    // same number for both inputs would pass an identifier-only check.
    #expect(red.confidence("red") > red.confidence("blue"))
    #expect(blue.confidence("blue") > blue.confidence("red"))
}

@Test func compiledModelCanBeKeptAndReloadedWithoutRecompiling() throws {
    let url = try #require(Fixture.model)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("walk-customModel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let kept = dir.appendingPathComponent("WalkKnownAnswer.mlmodelc")

    let first = try CustomModel(contentsOf: url, keepCompiledAt: kept)
    #expect(first.didCompile)
    #expect(first.compiled == kept)
    #expect(FileManager.default.fileExists(atPath: kept.path))

    let second = try CustomModel(contentsOf: kept)
    #expect(!second.didCompile, "an .mlmodelc must load directly, not be compiled again")
    let red = try second.classify(pixelBuffer: Fixture.tile(r: 1.0, g: 0.15, b: 0.15))
    #expect(red.best?.identifier == "red")
}

// MARK: - the refusals

@Test func aMissingModelIsRefused() {
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mlmodel")
    #expect(throws: CustomModel.Failure.self) {
        _ = try CustomModel(contentsOf: missing)
    }
}

@Test func aNonModelExtensionIsRefused() throws {
    let f = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(UUID().uuidString).txt")
    try "not a model".write(to: f, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: f) }
    #expect(throws: CustomModel.Failure.self) {
        _ = try CustomModel(contentsOf: f)
    }
}

@Test func garbageBytesNamedMlmodelAreRefused() throws {
    // The check that matters: the extension is right and the contents are not.
    // If this passes, `compileModel` is not actually validating anything.
    let f = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(UUID().uuidString).mlmodel")
    try Data(repeating: 0x41, count: 4096).write(to: f)
    defer { try? FileManager.default.removeItem(at: f) }
    #expect(throws: CustomModel.Failure.self) {
        _ = try CustomModel(contentsOf: f)
    }
}
