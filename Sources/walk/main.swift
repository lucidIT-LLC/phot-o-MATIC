import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WalkKit

// walk scan     <video> [--json]                 — what the engine found
// walk segments <video> [--handles s] [--out dir] — cut it
// walk <input> <output> [neutral|dramatic] [nits] — the 0.1.0 still grade
// walk contract [--expect <version>] | --version
//
// Measures before AND after, and refuses to claim a delta it could not compute.
// A grade that does not report what it changed is a guess wearing a number.

let args = CommandLine.arguments

// --- version and contract surface ---------------------------------------
// A consumer written against a specific Walk can verify it here and FAIL
// rather than proceed on stale instructions.

if args.count >= 2, args[1] == "--version" {
    print(Walk.version)
    exit(0)
}

if args.count >= 2, args[1] == "contract" {
    // walk contract                      -> print the contract
    // walk contract --expect <version>   -> exit 0 on match, 1 on mismatch
    if args.count >= 4, args[2] == "--expect" {
        let c = Walk.check(expecting: args[3])
        print("walk       \(c.actual)")
        print("expected   \(c.expected)")
        print("result     \(c.ok ? "OK" : "MISMATCH") — \(c.detail)")
        exit(c.ok ? 0 : 1)
    }
    print("walk \(Walk.version)")
    print("\ncapabilities (capability = version introduced):")
    for k in Walk.capabilities.keys.sorted() {
        print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(Walk.capabilities[k]!)")
    }
    print("\nNOT implemented — do not infer these from silence:")
    for k in Walk.notImplemented.sorted() { print("  \(k)") }
    exit(0)
}

// --- video subcommands -------------------------------------------------
// New in 0.3.0. `walk` with two paths still grades a still, unchanged.

if args.count >= 2, args[1] == "scan" {
    await ScanCommand.run(args)
    exit(0)
}

if args.count >= 2, args[1] == "segments" {
    await SegmentsCommand.run(args)
    exit(0)
}

if args.count >= 2, args[1] == "identifiers" {
    // The taxonomy read off the runtime, not off a documentation page.
    let ids = Classifier.supportedIdentifiers()
    print("ClassifyImageRequest supports \(ids.count) identifiers (built in, no model file)")
    let q = args.count >= 3 ? args[2].lowercased() : nil
    for id in ids.sorted() where q == nil || id.lowercased().contains(q!) { print("  \(id)") }
    exit(0)
}

guard args.count >= 3 else {
    FileHandle.standardError.write("""
        usage: walk scan <video> [--json] [--frames a-b] [--no-vision] [--fast]
                                 [--sigma <k>] [--floor <fraction>]
               walk segments <video> [--handles <sec>] [--lead <sec>] [--tail <sec>]
                                 [--out <dir>] [--fps <n>] [--dry-run]
               walk identifiers [substring]
               walk <in> <out> [neutral|dramatic] [targetNits]
               walk --version
               walk contract [--expect <version>]

        """.data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let lookName = args.count > 3 ? args[3] : "dramatic"
let nits = args.count > 4 ? (Double(args[4]) ?? 100) : 100

var look: HLGGrade.Look = (lookName == "neutral") ? .neutral : .dramatic
look.targetNits = nits

// Colour management DISABLED on load. The file holds HLG-encoded BT.2020
// values; letting ColorSync interpret them transforms the numbers before the
// transform runs.
guard let input = CIImage(contentsOf: inURL, options: [.colorSpace: NSNull()]) else {
    FileHandle.standardError.write("cannot read \(inURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [
    .workingColorSpace: linear,
    .outputColorSpace: srgb,
    .cacheIntermediates: false,
])

let w = Int(input.extent.width), h = Int(input.extent.height)
print("input         \(w) x \(h)  (\(String(format: "%.1f", Double(w*h)/1e6)) MP)")
print(String(format: "system gamma  %.3f   (BT.2390, target %.0f cd/m2)",
             HLGGrade.systemGamma(targetNits: nits), nits))

let before = HLGGrade.meanRaw(input)
guard before.valid else {
    FileHandle.standardError.write(
        "BASELINE MEASUREMENT FAILED (NaN) — refusing to grade without a baseline.\n"
            .data(using: .utf8)!)
    exit(1)
}
print(String(format: "before        R %.4f  G %.4f  B %.4f   luma %.4f   spread %.4f   [raw HLG]",
             before.r, before.g, before.b, before.luma, before.spread))

let t0 = Date()
let graded = HLGGrade.apply(to: input, look: look)
let after = HLGGrade.mean(graded, context: ctx, colorSpace: linear)
let ms = Date().timeIntervalSince(t0) * 1000

guard after.valid else {
    FileHandle.standardError.write("RESULT MEASUREMENT FAILED (NaN).\n".data(using: .utf8)!)
    exit(1)
}
print(String(format: "after         R %.4f  G %.4f  B %.4f   luma %.4f   spread %.4f   [%@, linear 709]",
             after.r, after.g, after.b, after.luma, after.spread, lookName))

let castDelta = after.spread - before.spread
print(String(format: "cast check    spread %+.4f  %@",
             castDelta,
             castDelta > 0.01 ? "<-- WARNING: the grade ADDED a colour cast" : "ok"))
print(String(format: "grade+measure %.1f ms", ms))

guard let cg = ctx.createCGImage(graded, from: graded.extent,
                                 format: .RGBA8, colorSpace: srgb) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}
guard let dest = CGImageDestinationCreateWithURL(
        outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot open \(outURL.path)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, cg, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("write failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote         \(outURL.path)")
