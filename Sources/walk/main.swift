import Foundation
import WalkKit

// walk scan     <video> [--json]                 — what the engine found
// walk segments <video> [--handles s] [--out dir] — cut it
// walk <input> <output> [neutral|dramatic] [nits] — the 0.1.0 still grade
// walk contract [--expect <version>] | --version
//
// Measures before AND after, and refuses to claim a delta it could not compute.
// A grade that does not report what it changed is a guess wearing a number.

let args = CommandLine.arguments

/// Soft-wrap for the contract printout. Terminal formatting only.
func wrap(_ s: String, width: Int) -> [String] {
    var lines = [String](), line = ""
    for word in s.split(separator: " ") {
        if line.isEmpty { line = String(word) }
        else if line.count + 1 + word.count <= width { line += " " + word }
        else { lines.append(line); line = String(word) }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

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
    for k in Walk.notImplemented.sorted() {
        print("  \(k)")
        // The reason is printed, not just the name. 0.4.0 exists partly because
        // `ingest.dump` as a bare word was read as a flat no while the app was
        // walking folders (#507); a one-word denial cannot say where the edge is.
        if let why = Walk.notImplementedReasons[k] {
            for line in wrap(why, width: 86) { print("      \(line)") }
        } else {
            print("      NO REASON RECORDED — this is a contract defect; see ContractTests")
        }
    }
    // WHETHER A VERDICT CAN BE RENDERED ON THIS HOST RIGHT NOW, which is a
    // different question from whether this build supports one. #513 named the
    // gap: app.proofSheet was declared with no statement that the sheet does not
    // judge, so a consumer could read a capability list and still not know that
    // nothing judges anything.
    let coach = Coaching.Coach()
    print("\ncoaching verdict (#513) — three bands, each with a reason and a next-flight lesson:")
    for band in Coaching.Band.allCases.sorted(by: { $0.order < $1.order }) {
        print("  \(band.label)")
        for line in wrap(band.promise, width: 84) { print("      \(line)") }
    }
    print("\n  rendered on this host: \(coach.isReady ? "YES" : "NO")")
    if let why = coach.unavailableReason {
        for line in wrap(why, width: 84) { print("      \(line)") }
        for place in coach.resolution?.searched ?? [] { print("      looked in \(place)") }
    } else if let c = coach.criteria {
        print("      criteria \(c.header.version) by \(c.header.owner), \(c.rules.count) rules — \(c.source)")
    }
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
                                 [--sigma <k>] [--floor <fraction>] [--criteria <file>]
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

// THE GRADE ITSELF LIVES IN WalkKit AS OF 0.4.0, not here.
//
// Every line of this sequence used to be inline in this file: the
// colour-management-disabled load, the raw baseline, the NaN guard, the grade,
// the managed re-measure, the cast check, the PNG write. The MCP front door
// (#507) needs all of it, and the only way to reach it from another target was
// to write it out again. Two copies of a measurement chain is the drift this
// repository exists to catch, so it moved to StillGrade and both front doors
// call the same code. What prints below is formatting; nothing here measures.
do {
    let r = try StillGrade.run(input: inURL, output: outURL,
                               lookName: lookName, targetNits: nits)
    print(String(format: "input         %d x %d  (%.1f MP)", r.width, r.height, r.megapixels))
    print(String(format: "system gamma  %.3f   (BT.2390, target %.0f cd/m2)",
                 r.systemGamma, r.targetNits))
    print(String(format: "before        R %.4f  G %.4f  B %.4f   luma %.4f   spread %.4f   [raw HLG]",
                 r.before.r, r.before.g, r.before.b, r.before.luma, r.before.spread))
    print(String(format: "after         R %.4f  G %.4f  B %.4f   luma %.4f   spread %.4f   [%@, linear 709]",
                 r.after.r, r.after.g, r.after.b, r.after.luma, r.after.spread, r.lookName))
    print(String(format: "cast check    spread %+.4f  %@", r.castDelta,
                 r.addedCast ? "<-- WARNING: the grade ADDED a colour cast" : "ok"))
    print(String(format: "grade+measure %.1f ms", r.milliseconds))
    if let out = r.output { print("wrote         \(out.path)") }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
