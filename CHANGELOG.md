# Changelog

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
