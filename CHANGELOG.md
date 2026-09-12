# Changelog

## 0.3.0 — 2026-09-12

Video. The spike measured in decision #495 becomes library API, a CLI, and a
window that shows what it found.

### The deprecation came first, before any feature code

#495's own last finding was that macOS 27 deprecates the entire classic
`AVAssetReader` path — `startReading()`, `copyNextSampleBuffer()`, `add(_:)`,
`alwaysCopiesSampleData` — and that the spike had used it throughout, so "a
library written today against Apple's published samples is BORN DEPRECATED."
Walk is not.

Everything reads through `AVAssetReader.outputProvider(for:)`, `reader.start()`
and `AVAssetReaderOutput.Provider.next()`; everything writes through
`AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`,
`writer.start()` and `PixelBufferReceiver.append(_:with:)`. The build emits no
deprecation warning from either path, and CI fails if one comes back — in the
diagnostics **and** in the source, excluding comments, because WalkKit names
every deprecated call in prose to explain what replaced it.

**The port was verified, not assumed. 8 of 8 known-answer frames, exact.** The
new reader produces the same 10-bit Y means as the deprecated one to within
0.0005 code values, which is the rounding of the three-decimal references
themselves:

| frame | new API | #495 reference |
|---|---|---|
| 2334 | 427.783 | 427.783 |
| 2340 | 420.763 | 420.763 |
| 2346 | 414.176 | 414.176 |
| 2347 | **439.098** | **439.098** |
| 2348 | 413.062 | 413.062 |
| 2352 | 426.450 | 426.450 |
| 2356 | 422.966 | 422.966 |
| 2359 | 419.040 | 419.040 |

**The new path is also faster, which was not expected.** Decode-only, same
process, same clip: `Provider.next()` 628.4 fps against `copyNextSampleBuffer()`
277.5 fps. Nothing was traded for not being deprecated.

**The platform floor moved from macOS 14 to macOS 26, and that is the price.**
`AVAssetReaderOutput.Provider` is `@available(macOS 26.0, *)`. There is no
version of this library that is both non-deprecated and runnable on macOS 14 —
the replacement does not exist there. Recorded in `Package.swift` at the
declaration rather than only here.

### The 6x that looked like the new API's fault

The first full-clip scan on the new reader ran 2771 frames in 72.9 s. Decode
alone is 4.4 s and the measured Core Image work was 9.4 s, leaving 63 s
unaccounted. The cause was a missing `autoreleasepool` around the synchronous
per-frame work:

| | wall | fps | CIAreaAverage | unaccounted |
|---|---|---|---|---|
| no autoreleasepool | 38.724 s | 71.6 | 2.686 ms/frame | 31.3 s |
| autoreleasepool | 6.454 s | 429.4 | 1.893 ms/frame | 1.2 s |

**The numbers are identical either way.** Without the pool you get the right
answer six times slower, with no error, and the obvious suspect is the new
async reader, which is innocent. Recorded at the call site in `FrameScanner`
with both measurements, because that is where someone will next be tempted to
delete it. A fresh `CIFilter` per frame also measured faster than a shared one
(429.4 fps against 387.0), so the shared instance is gone too.

### What shipped

- **`VideoReader`** — opens an asset, reports dimensions, rate, duration,
  estimated frame count, codec, bit depth and colour attachments; addresses a
  frame by index or PTS; iterates through a `Pass`. The working colour space is
  pinned to `kCGColorSpaceExtendedLinearITUR_2020`, because #495 measured the
  `CIContext` default as `ExtendedLinearSRGB` and the detector 4.2x more
  sensitive in pinned linear BT.2020 light.
- **`Frame`** — carries a `CVReadOnlyPixelBuffer` so it is `Sendable`. Y-plane
  statistics in code values, colour attachments as delivered, a detached copy
  that outlives the reader, and an sRGB display image.
- **`FrameScanner`** — per-frame `CIAreaAverage` across a clip. Measured on
  clip 0012: 2771 frames in 6.44 s, 430 fps, 1.867 ms/frame. With the exact
  stride-1 Y-plane pass as well: 29.17 s, 95.0 fps. Reports the **decoded**
  frame count and any frame index the decoder never delivered.
- **`EventDetector`** — see below.
- **`Classifier`** — `ClassifyImageRequest`, 1303 identifiers, no model file, no
  app bundle. Frame 2347 lightning 0.3435, frame 2348 0.0129: a 27x separation.
- **`SegmentBuilder`** — cut ranges with handles, and the shortfall **reported
  rather than clamped**. An event 0.70 s into a 16.2 s clip has 0.70 s of
  lead-in; the segment carries what was asked for, what was available and the
  difference.
- **`VideoWriter`** — re-encode only. HEVC Main10 + HLG, retimed so every source
  frame becomes one output frame.
- **CLI** — `walk scan <video> [--json]`, `walk segments <video> [--handles s]
  [--out dir]`, `walk identifiers [substring]`. The 0.1.0 still grade,
  `contract` and `--version` are unchanged.
- **App** — one SwiftUI window, `App/Walk.xcodeproj`. Opens a video or a folder,
  scans, and shows a proof sheet: thumbnail, timecode, and the numbers behind
  each moment, clickable for the rest. No preferences, no onboarding, no
  timeline editor.

### The detector, and the honest limit of it

#495's lesson was that a 640-wide `ffmpeg` pass missed frames 2334 and 2340 of
clip 0012 because of a **constant** threshold after the downscale. So the
threshold is derived from the clip's own statistics: a local median baseline
excluding the frame under test, and a MAD-derived robust sigma of the
relative-rise distribution.

**And that is not sufficient, which matters more than the part that works.** A
purely statistical threshold can never return "nothing found" — scale the bar to
the clip's own noise and a heavy-tailed distribution still puts frames past it.
So the threshold is `max(statistical, floor)` and the floor is a constant, named
as one at `EventDetector.Options.minimumRelativeRise`. The statistical half is
what stops a downscale artifact from hiding a real strike; the floor is what
lets an empty clip come back empty. Both are load-bearing and neither is
enough.

**Measured across all six storm clips, and it does not flatter the design:**

| clip | frames | statistical @12σ | threshold | bound by | candidates |
|---|---|---|---|---|---|
| 0007 | 1560 | 0.0958% | 1.000% | floor | 1 |
| 0008 | 974 | 0.1049% | 1.000% | floor | 5 |
| 0009 | 887 | 0.1890% | 1.000% | floor | 3 |
| 0010 | 2792 | 0.0000% | 1.000% | floor | 1 |
| 0011 | 3386 | 0.0000% | 1.000% | floor | 7 |
| 0012 | 2771 | 0.3009% | 1.000% | floor | 13 |

**The statistical half never bound on any clip.** On 0010 and 0011 the robust
scale estimator collapsed to exactly zero — more than half the frames sit on
their own local median, so the clip supplies no noise scale at all. On this
material the constant is doing all the work, and the statistics are a guard
against the opposite failure (a clip noisier than 1%) that did not occur here
and is therefore **unexercised on real footage**. `Result.scaleCollapsed`
reports the collapse; the app prints it on screen. A zero threshold now refuses
rather than flagging every frame above its own median — inability to measure
must not present as detection.

12,370 frames decoded across the six clips in 28.8 s. No clip returned zero
candidates, so "nothing found" is **proven only by unit test**, not by real
material.

### Nine frames of clip 0012 classify as lightning, not six

Decision #495 established six strikes in clip 0012. The detector flags 13
luminance candidates and Vision separates them cleanly:

| frame | rise | lightning |
|---|---|---|
| 1194 | +1.09% | 0.0056 |
| 1272 | +8.15% | 0.0044 |
| 1282 | +13.21% | 0.0049 |
| 1843 | +2.47% | 0.0066 |
| 2334 | +18.48% | 0.2112 |
| 2340 | +8.90% | 0.0781 |
| 2347 | +36.03% | 0.3435 |
| 2352 | +26.17% | 0.1255 |
| 2356 | +22.86% | 0.1125 |
| 2359 | +14.56% | 0.2568 |
| 2367 | +5.15% | **0.5581** |
| 2372 | +1.59% | **0.4951** |
| 2388 | +3.69% | **0.6616** |

The four negatives sit at 0.0044–0.0066 and the nine positives at 0.0781–0.6616:
a 12x gap between the highest negative and the lowest positive. **Three frames
that #495's six-strike count does not include — 2367, 2372 and 2388 — classify
lightning HIGHER than 2347 does**, and 2372 does it on a +1.59% luminance rise
barely above the floor. Luminance alone under-counts, one level deeper than
#495 found for 2334 and 2340.

What that is: MEASURED, that nine frames classify as lightning above 0.078.
INFERRED and **not** claimed, that they are nine distinct strikes — the frames
have not been looked at, and they could be the decay of one long flash or cloud
lit by a bolt outside the frame. The count of *strikes* in clip 0012 is still
open.

### Vision's modern API and the old one agree exactly

`ClassifyImageRequest` (the current Swift surface) and `VNClassifyImageRequest`
(what #495 measured) returned **identical confidences to four decimals on 15 of
15 frames**. Walk uses the modern one. One timing sample, modern call first:
18.7 ms against 13.7 ms, which is warmup as much as anything and is not claimed
as a difference.

### The write path, and why passthrough is not in it

Passthrough is **open defect task #721**: 122 samples appended, every
`append()` returning true, `writer.status` completed, `writer.error` nil, and
100 decodable frames in the file. 22 frames gone with no error anywhere in the
API, and surviving frames bit-exact so a spot check passes. It is 180x faster
than re-encode and it is not merged. `VideoWriter` says so at the type, and the
CLI says so after every run.

Re-encode, measured: 100 frames requested, pulled and appended; 100 decodable
on readback; 3.3333 s at 30.00 fps; `hvc1`, 10 bit, `ITU_R_2020`,
`ITU_R_2100_HLG`; 99 fps encode. Source frame 2347 landed at output frame 47 at
Y mean **439.079** against 439.098 — a delta of 0.019 code values, **0.0044%**,
through a full HEVC Main10 round trip. A one-frame event survives a 60→30
conform.

**`VideoWriter` re-reads what it wrote and counts the decodable frames,** and
throws `shortOutput` if that count differs from what it appended. That is the
control defect #721 did not have.

### Two defects found in this work, both recorded where the fix lives

**1. The retime ratio truncated, and every check still passed.** Computing
`(1/30) / (1001/60000)` through a `Double` gave **1999/1001** instead of
2000/1001. All 100 frames landed, readback verified, HLG survived — and the
output came back **3.3317 s at 31.58 fps** instead of 3.3333 s at 30.00. A wrong
answer that passes everything except reading the duration. Now exact integer
arithmetic, with the wrong value asserted in a test so the Double path cannot
come back.

**2. The codesign failure has a root cause, and it is not the build system.**
0.2.0 recorded `swift test` failing with *"resource fork, Finder information, or
similar detritus not allowed"* and prescribed `--build-system native`. The
workaround works and the diagnosis was wrong. This repository lives in
`~/Documents`, an iCloud Drive File Provider domain; the File Provider stamps
`com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P` onto bundle
directories, and `codesign` refuses to sign a bundle carrying them. Proven both
directions:

```
swift test                              -> CodeSign fails on WalkKitTests.xctest
swift test --scratch-path <outside>     -> 30 tests pass
xcodebuild, products in ./App/Build     -> CodeSign fails on Walk.app
xcodebuild, products under ~/Library    -> BUILD SUCCEEDED
```

It is the build **location**, not the build system, and the same cause was about
to block the app. Fixed in a `Makefile` that puts both build trees under
`~/Library/Developer/Xcode/DerivedData`, with the measurement at the setting.
Two symptoms collapse into it — a small count, and not offered as anything
larger than a local root cause for this repository's build.

Setting `SYMROOT`/`OBJROOT` in the Xcode project was tried first and rejected by
the tool: *"Packages are not supported when using legacy build locations"*. A
`WorkspaceSettings.xcsettings` was tried second and did not move xcodebuild's
products, so it was deleted rather than committed with a comment claiming
something it does not do.

### The v0.2.0 tag was cut on a red CI run

Measured while porting: run **34698731947**, the CI for the v0.2.0 tag, **failed**
on `macos-15` / Xcode 16.4 / Swift 6.0 — `static property 'kernel' is not
concurrency-safe because non-Sendable type 'CIColorKernel' may have shared
mutable state`. The tag was created anyway, which means *the tag-matches-source
control that 0.2.0 introduced never actually ran on 0.2.0.* Fixed with
`nonisolated(unsafe)` on the kernel and its invariant stated; CI now runs on
`macos-26`, which is also the only runner that can build a macOS 26 floor.

### Tests

30 tests, 29 of which run anywhere.

- The detector and `SegmentBuilder` are tested on plain numbers: a flat series
  finds nothing and says so in words; heavy-tailed noise with no event produces
  events when the floor is removed and none when it is kept; a series with no
  measurable variation refuses rather than flagging half of it; a shortfall is
  reported with what was asked for still in the record; the event frame is
  inside its segment at every handle length including zero.
- The known-answer tests run against clip 0012 and assert the table above,
  `yMax == 1007` unclipped, the Vision separation, and the 60→30 round trip.
- **`swift test` in CI does not run them.** The material is 780 MB of the
  operator's archive on an external volume and cannot be in the repository. A
  test that only runs when the clip is *absent* prints a block naming every
  check that was skipped, so a green CI run cannot be mistaken for a verified
  known answer.

### The version contract will flag Pixel 2.5.0, and that is it working

Pixel 2.5.0 §8.5 is written against Walk 0.2.0. `walk contract --expect 0.2.0`
exits 1 with *"Walk is NEWER than the consumer was written against — its
instructions may describe changed behavior and must be re-verified."* CI
**requires** that refusal. The studio pack was not touched; Pixel's skill needs
re-verification against 0.3.0 by whoever owns it.

### What it still does not do

`walk contract` prints the list. Named rather than left to silence:
`video.write.passthrough` (defect #721), `video.audio` (never read, retimed or
written), `ingest.dump`, `page.bestWorst`, `touchup`, `app.drive`,
`fcpxml.export`, `coreml.custom`. The app has **no sandbox** — deliberately,
with the trade stated at `WalkApp`: under App Sandbox a path cannot be passed on
the command line, so the proof sheet could never be run against known material
and *seen* to be right, and an app whose output cannot be verified is the thing
this repository exists to avoid. Re-enabling it is real work.

### And what Walk will not do

Session #228 measured that the operator's best-selling photograph fails nearly
every technical metric taken on it: 66.57% shadow, clipped at both ends, the
highest noise floor and the smallest file of the set. A tool that hid his best
seller because it scored badly would be worse than no tool. Walk sorts and
flags. It reports measurements and confidences and it renders no keep/pitch
verdict, in the CLI, in the JSON, and on screen. That judgment is the
operator's, or Pixel's on the finals.

## 0.2.0 — 2026-09-12

The version contract, and a test suite that asserts the failure paths.

**Added**
- `Walk.version`, `Walk.capabilities` (capability → version introduced), and
  `Walk.notImplemented` — so a consumer cannot infer capability from silence.
- `Walk.check(expecting:)` and `walk contract [--expect <version>]`. Exit 0 on
  match; exit 1 with a direction on mismatch — *newer* means the consumer's
  instructions describe changed behavior, *older* means claimed capability is
  absent.
- `walk --version`.
- `Tests/WalkKitTests` — 8 tests. Three assert the contract REFUSES (newer,
  older, unparseable). One pins the BT.2390 system gamma to the standard:
  1.2 at 1000 nits, 0.78 at 100. One asserts a NaN reading reports itself
  invalid.
- GitHub Actions CI. Builds, tests, and exercises the contract as a control:
  it must pass on its own version and **must fail** on a newer one and on
  garbage. On a tag, CI refuses to release if the tag and `Walk.version`
  disagree.

**Why this exists.** The defect this closes is prose describing code that has
since changed, with nothing able to notice — retired KB numbers cited as live
authority, a rule naming a renamed connection, a reversed sign that passed every
verifier. A document that cannot detect its own staleness is served as current
indefinitely. The contract lets a consumer fail loudly instead.

**Known**
- `swift test` fails locally under the Xcode build system with *"resource fork,
  Finder information, or similar detritus not allowed"* at the codesign step —
  an xattr artifact, not a code fault. Use `swift test --build-system native`;
  CI does.
- Still stills only. The video capability measured in decision #495 is not in
  this repository.

## 0.1.0 — 2026-09-12

First release. HLG→SDR transform, measurement, and the grade loop.

**Added**
- `WalkKit.HLGGrade` — inverse HLG OETF, OOTF, BT.2020→709 primaries, Hable
  filmic tone map, all in one `CIColorKernel`.
- `HLGGrade.systemGamma(targetNits:)` — BT.2390 derivation.
- `HLGGrade.mean` / `meanRaw` — whole-image measurement with an explicit
  validity flag.
- `walk` CLI — grades, measures both ends, runs the cast check.

**Two defects found and fixed on the first run, both recorded in source:**
- **System gamma hardcoded to 1.2.** That is the 1000 cd/m² HDR value; SDR is
  0.78. Gamma above 1 darkens shadows, so the entire foreground of the test
  frame — treeline and houses — rendered pure black. Correcting it raised mean
  luma from 0.0654 to 0.2049, a 3.1× change from one constant.
- **`CIAreaAverage` returns NaN on an unmanaged image**, silently. The first run
  reported a graded result against a NaN baseline, which is exactly what the
  method forbids. `meanRaw` now renders and averages on the CPU, and the CLI
  refuses to proceed on an invalid baseline.

**Known**
- `CIColorKernel(source:)` uses the deprecated Core Image Kernel Language.
  Works on macOS 27; should move to a Metal kernel.
- Stills only. Video read/write via AVFoundation is measured but not yet wired.
