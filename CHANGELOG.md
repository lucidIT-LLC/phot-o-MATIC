# Changelog

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
