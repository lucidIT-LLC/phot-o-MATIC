# Walk

**An on-device photographic engine for macOS.** Measurement first,
grading second, no third-party application required.

Walk is the engine. [Pixel](https://github.com/lucidIT-LLC/o-matic-studio) is the
photography coach who uses it. The engine is deterministic and carries no model;
the judgment lives in Pixel. That separation is deliberate — a model upgrade must
never silently change a measured value.

---

## Why it exists

Grading a photograph well requires a loop: **measure → adjust → re-measure →
converge.** Most automation paths can adjust but cannot measure:

| Path | Read-back |
|---|---|
| **Core Image (Walk)** | full buffer, 24 MP in ~8 ms |
| Affinity `readPixel` | ~4.7 µs per pixel |
| Pixelmator `pick color` | one pixel per Apple Event |
| Screenshot / computer use | no real pixel data |

Walk owns the read-back, so the loop closes.

## What it does today

- **HLG → SDR conversion** (ITU-R BT.2100 / BT.2390) with a filmic tone map
- **Whole-image measurement** — mean channels, luma, and a colour-cast check
- **A grade that reports what it changed**, and refuses to run without a baseline

## Usage

```
walk <input> <output> [neutral|dramatic] [targetNits]
```

```
$ walk strike.png graded.png dramatic
input         1458 x 1822  (2.7 MP)
system gamma  0.780   (BT.2390, target 100 cd/m2)
before        R 0.5033  G 0.5025  B 0.4956   luma 0.5021   spread 0.0077   [raw HLG]
after         R 0.2112  G 0.2026  B 0.2090   luma 0.2049   spread 0.0085   [dramatic, linear 709]
cast check    spread +0.0008  ok
grade+measure 446.5 ms
```

## Build

```
swift build -c release
```

No Xcode project, no bundle, no signing. Requires the macOS SDK.

---

## Design rules

**1. Every operation reports what it changed.** A grade without a before and an
after is a guess wearing a number. `walk` exits non-zero rather than grade an
image whose baseline it could not measure.

**2. The cast check is mechanical, not visual.** Channel spread is measured
before and after. A grade that *increases* spread on a near-neutral subject is
adding a colour cast, and says so.

**3. Constants come from the standard, with the standard cited.** The HLG system
gamma is derived from target display luminance per BT.2390 — `γ = 1.2 + 0.42 ·
log10(Lw/1000)` — not hardcoded to the widely-quoted 1.2, which is the value for
a 1000 cd/m² HDR display and crushes SDR shadows to black.

**4. Silent failures get named in the source.** `CIAreaAverage` returns NaN on an
unmanaged image with no error. That is recorded where the workaround lives, not
in a commit message nobody reads.

## License

MIT © lucidIT LLC
