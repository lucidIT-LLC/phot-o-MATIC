// swift-tools-version: 6.2
import PackageDescription

// PLATFORM FLOOR IS macOS 26, RAISED FROM 14 IN 0.3.0, AND IT IS NOT A PREFERENCE.
// The classic AVAssetReader path — startReading(), copyNextSampleBuffer(),
// add(_:), alwaysCopiesSampleData — is deprecated as of macOS 27 (measured in
// the SDK 27.0 headers; recorded as decision #495). Its replacement,
// AVAssetReaderOutput.Provider, is `@available(macOS 26.0, *)`. There is no
// version of this library that is both non-deprecated and runnable on macOS 14:
// the replacement simply does not exist there. Raising the floor removes the
// deprecation with no compatibility shim, which is the outcome worth having.
let package = Package(
    name: "Walk",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WalkKit", targets: ["WalkKit"]),
        .executable(name: "walk", targets: ["walk"]),
        // 0.4.0: the third front door. One library, three ways in — the CLI,
        // the app, and now an MCP server, which decision #507 makes the primary
        // one: the product is the conversation reaching this machine.
        .executable(name: "walk-mcp", targets: ["walk-mcp"]),
    ],
    targets: [
        .target(name: "WalkKit"),
        .executableTarget(name: "walk", dependencies: ["WalkKit"]),
        // NO DEPENDENCIES, DELIBERATELY. MCP over stdio is newline-delimited
        // JSON-RPC 2.0 and the whole wire layer is JSON.swift plus
        // Transport.swift. Pulling in an SDK would add a second version contract
        // to keep in step with this one — and §8.5 exists because keeping two
        // things in step by hand is what fails here.
        .executableTarget(name: "walk-mcp", dependencies: ["WalkKit"]),
        // The fixture is a 16 KB CreateML model with a known answer (red/blue),
        // carried so the custom-Core-ML path has a test that runs anywhere.
        // KnownAnswerTests needs 780 MB on an external volume and skips without
        // it; this one must not, which is why the model is in the repository and
        // Tools/make-known-answer-model.swift regenerates it.
        //
        // `.copy`, NOT `.process`, AND THE DIFFERENCE IS THE WHOLE TEST.
        // MEASURED: with `.process`, the build system recognises a Core ML model
        // and compiles it, so what lands in the bundle is `WalkKnownAnswer.mlmodelc`
        // and the `.mlmodel` is gone. The test would then either fail to find its
        // fixture or silently exercise the already-compiled path — proving that
        // the BUILD can compile a model, which was never in question, instead of
        // that WALK can compile one at runtime, which is the claim being made.
        // `.copy` carries the bytes through untouched.
        .testTarget(name: "WalkKitTests", dependencies: ["WalkKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
