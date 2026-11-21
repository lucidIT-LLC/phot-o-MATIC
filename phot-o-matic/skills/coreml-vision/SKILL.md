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

## On-device first — Core ML is the default inference layer

**Mac-native, on-device first; cloud only as a flagged exception.** Use Core ML
as the default inference layer: https://developer.apple.com/documentation/coreml

- **Vision** for requests that wrap Apple models (classification, horizon,
  saliency, subjects, or a custom model via `VNCoreMLModel`).
- **Core Video** to hold and pool `CVPixelBuffer` frames.
- **Create ML Components** to compose image transformers and estimators, then
  fit or wrap a Core ML model for use in-app or through phot-o-MATIC
  (`coreml.custom`).
- phot-o-MATIC already exposes `classify.vision` (since 0.3.0) and
  `coreml.custom` (since 0.5.7). Prefer those when the plugin is present. Call
  `walk_contract` before relying on the list.
- **MLX is secondary.** Use it only when a model has no acceptable Core ML
  conversion, and say you are leaving the default path. phot-o-MATIC does not
  ship an MLX runtime.

Never silently send a photograph or clip to a cloud vision API.

## Create ML Components (on-device train / transform)

Source: https://developer.apple.com/documentation/createmlcomponents (macOS 13+).

Components are transformers and estimators composed with `.appending`; fitting
turns an estimator into a transformer. Useful image pieces:

- `ImageReader`, `ImageFeaturePrint` / `ImageFeatureExtractor`,
  `MLModelImageFeatureExtractor`
- Geometry: `ImageCropper`, `ImageScaler`, `ImageFlipper`, `ImageRotator`
- Look: `ImageColorTransformer`, `ImageExposureAdjuster`, `ImageBlur`,
  `RandomImageNoiseGenerator` (augmentation)
- Classification: `ImageFeaturePrint` plus a logistic or fully connected
  classifier; multi-label via `FullyConnectedNetworkMultiLabelClassifier`
- Adaptors: a Core ML model used as a classifier or regressor

Fit and run on the Mac; export or wrap as Core ML for `coreml.custom` or
Vision. No cloud training for a personal look model. These are for **model
pipelines**, not a replacement for a measured one-probe edit in Pixelmator Pro.

If the operator wants a personal "looks like my keepers" model, propose a
Create ML Components pipeline trained on their labeled stills and deployed via
Core ML. That is a project, not a silent download.

## 32 GB Apple silicon budget

On a 32 GB Apple silicon Mac, leave headroom for Final Cut Pro, Pixelmator Pro,
phot-o-MATIC, Photos, and any running virtual machine.

- Prefer Apple Vision models and compact Core ML classifiers over general
  language models for "what is in this frame."
- Keep one custom vision model in memory at a time; unload it before opening
  Final Cut Pro or Generate Fill if memory is tight.
- Do not stack 30B-class or multi-model pipelines, and do not assume 64 GB.
- If MLX is the only option, pick a quantized size that leaves several GB
  free, or refuse and say why.

Compiled `.mlmodelc` models on the Neural Engine are the default deploy shape.
Always print `modelDescription` input shapes; never guess. Inference is not
the grade — measure, then edit, then re-measure.
