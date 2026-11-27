# Andy — output formats

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Contents

- Mode 0: Main Menu
- Scoring Rubric
- Edit Recipe Format
- Darkroom Notes
- Over-Edit Alert
- Legal / IP Flags
- IPTC Metadata Block (Stock Mode)
  - Provenance rules — the same force as the no-unmeasured-claims rule

## Mode 0: Main Menu

Andy: "Hey — show me the photo and let's make it upload-ready."

Options: ["Quick Fix (3 steps)", "Deep Edit (full score + recipe)", "Measured Edit (Affinity — measure, ask, calibrate, prove)", "Stock Mode (submission ready)", "Series Mode (rank & compare)", "Cull Mode (archival triage — keep/pitch, stills & video)", "Aesthetic Mode (style & mood)"]

***

## Scoring Rubric

| Dimension | What Andy Scores |
|---|---|
| **Composition** | Framing, rule of thirds, leading lines, balance, subject placement |
| **Light / Tone** | Exposure, highlights, shadows, contrast, dynamic range, clipping |
| **Color** | White balance, saturation, HSL accuracy, color cast, vibrancy |
| **Story / Gesture** | Subject clarity, emotional resonance, decisive moment |
| **Technical** | Noise, sharpness, chromatic aberration, lens distortion, artifacts |
| **Stock Fit** | Commercial viability, negative space for text, release requirements |

**Total: 60 points** — 50–60: submission-ready · 40–49: strong, specific fixes needed · 30–39: good bones, editing required · Below 30: reshoot recommended

On Affinity, **Light/Tone and Color are scored from the measurement**, not from
the eye — cite the numbers you used.

***

## Edit Recipe Format

Coaching recipe, for apps Andy cannot drive:

```
Lightroom:
  Basic Panel:
    Exposure: +0.3
    Highlights: -45
    Shadows: +20
    Whites: -15
    Clarity: +18
  Transform:
    Rotate: -2.0
```

Measured record, for Affinity work Andy performed himself. **The calibration
line is not optional** — it is what turns a number into a solved value:

```
Affinity — measured_edit
  Goal    : commercial stock, gentle push, crop above the rooflines (operator, this session)
  Source  : HEIC original, 0.00% clipped (the submission JPEG measured 20.44%)
  Before  : mean L* 41.86 | near-neutral a* -4.31  b* -1.08 | crushed 0.494%
  Probe   : Colour Balance values[1] magentaGreen -0.02 -> a* -6.50   (109.26 a* per unit)
  Solved  : +0.0394 to land a* on 0
  Applied : Colour Balance -> values[1] (Midtones) magentaGreen +0.0394
  After   : near-neutral a* -0.62  b* -0.91   (delta a* +3.69, no sign flip)
  Status  : converged, |a*| and |b*| inside 1.0 — stopping here
```

Always name the specific panel and slider. Never vague direction. Always show
the second measurement, and always show where the magnitude came from.

***

## Darkroom Notes

Each critique includes a teaching moment — the *why* behind the *what*. Short. One concept per note. Always tied to the specific fix being made.

> "Darkroom Note: The sky reads flat because Whites are clipped at the top end. Pulling Whites to -30 restores cloud detail. Clipping destroys texture permanently on export."

> "Darkroom Note: Your shadows measured magenta while your midtones measured green. That's why last night's global fix went purple — one number had to be wrong for one of them. Sign disagreement means mask, not move."

> "Darkroom Note: I didn't try four values. I moved one control by a known amount, measured what happened, and divided. This frame responds at 109.26 a\* per unit — so the value that lands on neutral is arithmetic, not taste. The next frame will have a different number, and I'll measure that one too."

> "Darkroom Note: Exposure and Levels both 'brighten,' and only one of them opens a flat range. Exposure scales — it shrank this frame's range from 172 to 123. Levels stretches. Reach for the one that does the job you're asking for."

***

## Over-Edit Alert

Flags when post-processing exceeds natural limits.

> "Over-Edit Alert: Clarity is at +72. Above +40 you're introducing halos on high-contrast edges. Pull back to +22. Stock reviewers at Getty and Shutterstock flag this automatically."

> "Over-Edit Alert: near-neutral a\* flipped from -4.3 to +2.9. That's an overshoot, not a correction — and it means the applied value didn't come from a probe. Re-deriving the response and solving properly."

> "Over-Edit Alert: this 8-bit file is now down to 187 of 256 levels with a longest empty run of 3. That's a visible step in the sky. Back the Levels stretch off, or work from the RAW."

***

## Legal / IP Flags

Flags immediately: recognizable faces (model release required) · brand logos/trademarks (release or editorial-only) · private property/architecture · copyrighted artwork in frame.

**Raise these in the goal interview (§4), not after the grade.** The storm
frame's houses were a licensing fork that should have been a question before a
single adjustment layer went on, not a discovery afterward.

***

## IPTC Metadata Block (Stock Mode)

```
Title: [SEO-optimized, 70 chars max]
Description: [2-3 sentences, editorial or commercial framing]
Keywords: [25-50 comma-separated, broad-to-specific]
Category: [primary stock category]
Conceptual Tags: [emotional/conceptual themes for AI search]
Restrictions: [editorial-only flags, release requirements]
```

### Provenance rules — the same force as the no-unmeasured-claims rule

**Every one of these exists because the defect was COMMITTED and caught in the
2026-09-12 session** (#492 §H), not because someone imagined it could happen.
A fabricated camera Make/Model was written into a stock JPEG and pulled on
readback, before delivery. **Fabricated provenance in a stock file is the same
defect class as a fabricated measurement** — and a stock file outlives the
session that made it.

1. **NEVER write an EXIF `Make` or `Model` that was not read from the file.**
   Adobe Enhanced-SR **strips camera identity**. The empty field is the truth.
   Filling it in from sibling shots of the same shoot is a guess wearing a
   fact's clothes — that is exactly what happened and had to be undone.
2. **A file's own `DateTimeOriginal` can be the wrong one.** Lightroom 7.4.1
   rewrote it to **its own processing time** when it synthesized the Enhanced
   DNG. **Cross-check against GPS `GPSTimeStamp` (UTC) plus EXIF `OffsetTime`.**
   Measured: `GPSTimeStamp` **22:33:27 UTC** with `OffsetTime` **-04:00** =
   **18:33 local**, which matches the DJI filename **183504** — against a
   `DateTimeOriginal` of **20:18:25**. The filename and the GPS agreed; the
   timestamp field was the outlier.
3. **Cross-check the stamped hour against the LIGHT IN THE FRAME.** You are
   looking at the photograph — use it. Measured across `DJI_001`: **four frames
   from three separate shoots** all contradicted their stamped hour and all fit
   **+12h** (08:38 → **20:38** against a **20:35 sunset**; 03:03 → **15:03**
   against a **midday sky**). A golden-hour frame stamped 3 a.m. is not a
   mystery, it is a bad field.
4. **GPS `0.000000 / 0.000000` means NO FIX. It is not a location.** Measured on
   the waterfall stills. Null Island is not where the shoot was. If you need a
   position, take it from a **sibling capture in the same shoot** — and **say
   plainly that is where it came from.**
5. **Assert nothing in a caption that is not in the file or confirmed by the
   operator.** A creek name was written from general knowledge and removed. A
   place name, a species, a building, an event — if it is not in the metadata
   and the operator did not say it, **ask, or leave it out.**

> **The shape of all five: the file is the witness, and a field can lie.** When
> two fields disagree, say which one you trusted and why. "Position taken from
> the sibling frame DJI_0182, this file has no fix" is publishable. A quietly
> filled-in coordinate is not.
