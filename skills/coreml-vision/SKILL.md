---
name: coreml-vision
description: Run CoreML models and Apple Vision from the command line on macOS — no Xcode project, no app bundle. Use when measuring or classifying images and video, probing an .mlmodelc, detecting horizons/saliency/subjects, or when someone says a model needs Xcode. Carries the measured API shapes for the current Vision release, which changed and will break remembered code.
---

# CoreML and Vision from a command line

**The gate is not tooling.** `MLModel.compileModel(at:)` is a RUNTIME api in
CoreML.framework, not a build step. Measured 2026-09-12: it compiled a custom
`.mlmodel` in **16 ms**, loaded through `MLModel(contentsOf:)`, and ran through
`VNCoreMLModel` from a plain `swiftc` binary — no Xcode project, no app bundle,
no deprecation warnings. A malformed model was refused, so the probe can fail.

`coremltools` gates model **authoring**, not loading. Never report its absence
as a blocker without saying which of the two it blocks.

## Probe a model before you use it

An `.mlmodelc` is already compiled — `MLModel(contentsOf:)` opens it directly.
NEVER guess a model's input shape. Print it:

```swift
let m = try MLModel(contentsOf: url)
for (k, v) in m.modelDescription.inputDescriptionsByName {
    if let c = v.multiArrayConstraint { print(k, c.shape) }
    if let c = v.imageConstraint { print(k, c.pixelsWide, c.pixelsHigh) }
}
```

Compile with `swiftc -O probe.swift -o probe`. That is the whole toolchain.

## Vision API shapes — MEASURED, and they are not what older code assumes

Every one of these cost a failed compile on 2026-09-13:

| What you reach for | What it actually is |
|---|---|
| `handler.perform(...)` | **async** — the call site must be async, not a plain `for` loop in `main` |
| `DetectHorizonRequest().angle` | `Measurement<UnitAngle>`, NOT a Double. Use `.converted(to: .degrees).value` |
| saliency `.heatMap` | a `PixelBufferObservation`, not a CVPixelBuffer. Its `.pixelBuffer` is a `CVReadOnlyPixelBuffer`, which `CVPixelBufferGetWidth` refuses |
| `.salientObjects` | NON-optional `[RectangleObservation]`. Optional-chaining it fails to compile |

**Prefer `salientObjects` bounding boxes over the raw heat map.** It is the
documented high-level result, it avoids the pixel-buffer type entirely, and it
answers "where does the eye go" directly. Boxes are normalized with origin at
BOTTOM-LEFT — `1 - midY` converts to "percent down".

`DetectHorizonRequest` reports a **confidence**; print it. A horizon angle with
no confidence is not a measurement.

## Models already on the machine

Photomator ships **13 compiled CoreML models** at
`/Applications/Photomator.app/Contents/Frameworks/PXMPro.framework/Versions/A/Resources/`:
SuperResolution, NoiseReduction, NoiseAnalysis, SkyDetection, HorizonDetection,
AutoCrop, ObjectDetection, ColorFixing, Decontamination, Deposterize,
DeposterizeAnalysis, MaskRefinement, ImageAnalysis. All load with
`MLModel(contentsOf:)` — verified 2026-09-13.

**They are the vendor's, licensed to the app.** Loading them outside it is a
licensing question for the operator, not a technical one, and it is his call to
make explicitly. Apple's own Vision and Core Image frameworks are public API and
carry no such question — reach for those first and say plainly when you have not.

## The rule this skill exists to enforce

An app with no scripting dictionary is not an app with no capability. Photomator
has no `.sdef` and no App Intents and is completely undriveable by AppleScript —
and its entire engine is thirteen files on disk that load in one line. **Check
where the capability lives, not where the interface is.**
