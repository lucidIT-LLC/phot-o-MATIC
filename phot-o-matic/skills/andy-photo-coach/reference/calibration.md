# Andy — calibrate, don't sweep

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Contents

- 5. CALIBRATE, DON'T SWEEP
  - The method
  - Probe, measure, UNDO, then apply the solved value
  - Two worked examples, and they teach opposite lessons
  - Measured transfer functions — examples of the output, NOT constants
  - Probe one zone at a time
  - Sweeping is the fallback, and it announces itself

## 5. CALIBRATE, DON'T SWEEP

**Parameter sweeping is retired as the default method.** Operator ruling, #491:
*"the playing around thing things costs tokens."* Applying a control at four
values and picking one by eye can never tell you *why* the value worked, so the
next frame starts from zero again.

### The method

1. **Measure the baseline.** Use a **settle read** (§9.2) — discard the first
   read after any document change.
2. **Apply ONE probe** at a known magnitude. Big enough to move the reading
   well clear of the noise floor; small enough not to clip.
3. **Re-measure**, settled. Compute the delta.
4. **Per-unit response** = delta ÷ probe magnitude. That is the transfer
   function for *this control, on this frame, in this zone*.
5. **Solve** for the value that lands the target: `value = targetDelta ÷ perUnit`.
6. **Apply it, re-measure, report both numbers.** If the result misses by more
   than about 10%, the response is non-linear across that span — re-derive at
   the new operating point. Do not start guessing.

**Two probes of about four seconds each replace a dozen guesses.**

### Probe, measure, UNDO, then apply the solved value

**`doc.undo()` cleanly removes an adjustment layer and restores the render
exactly.** Measured 2026-09-12 (#492 §B): layers went **1 → 0** and the observed
channel max returned to **58252**, its pre-probe value. The probe leaves nothing
behind.

**That makes calibration cheap, and it changes the shape of the method.** Do not
probe on top of a probe and do not try to subtract the first layer's effect
arithmetically:

1. Apply the probe as its own adjustment layer.
2. Measure, settled.
3. **`doc.undo()`** — you are back to baseline, provably.
4. Apply the **solved** value as a single clean layer.
5. Re-measure and report both numbers.

The frame the operator keeps then carries **one** adjustment layer holding a
solved value, not a probe plus a correction. **Caveat that belongs with this:**
undo is reliable for an `AddChildNodesCommandBuilder` insertion. It is **not**
reliable for a canvas resize — see §9.15, where a script crop is one-way.

### Two worked examples, and they teach opposite lessons

**SplitToning — when the honest move is to declare a ceiling.** Measured
2026-09-12 (#492 §E). Its parameters are plain scalars
(`highlightsHue`, `highlightsSaturation`, `shadowsHue`, `shadowsSaturation`,
`balance`), `setParameters` accepts a plain object, and readback confirms — so
the control is fully reachable. **It still cannot do the job.** Its hue control
barely rotates the *output*: `shadowsHue` **40°** produced a **31° Lab move**
and **70°** produced **37°** — **30° of input bought 6° of output.** And at
`shadowsSaturation` 0.30 the near-neutral a\* went **+1.11 → +5.2 at every hue
tested**. **SplitToning cannot warm a subject without casting the frame's
neutrals.**

> **So solve for the largest value that still holds the neutral criterion, and
> SAY THE CEILING EXISTS.** Do not keep sweeping for a value that is not there.
> "This control tops out before your target, here is the number where it stops"
> is a finding. Four more guesses is spend.

**Levels white point — when one probe ends the work.** Measured the same day
(#492 §F): `max_out = max_in ÷ whiteLevel`, **exactly**. Predicted **61318**,
measured **61318**. **Probe once to CONFIRM the model, then solve in closed
form.** Once a control's model is verified, sweeping it is not caution — it is
re-deriving arithmetic you already have.

### Measured transfer functions — examples of the output, NOT constants

All measured 2026-09-12 on the frames named.

| Control | Measured response | Frame |
|---|---|---|
| `ColourBalance` `magentaGreen`, global | **109.26** a\* per 1.0 | storm |
| `ColourBalance` `magentaGreen`, inside a sky mask | **72.83** a\* per 1.0 | storm |
| White Balance | **70.36** b\* per 1.0 | — |
| `magentaGreen`, **shadows** zone | **-225.5** a\* per 1.0 | waterfall |
| `magentaGreen`, **midtones** zone | **-81.6** a\* per 1.0 | waterfall |

**Do not reuse these numbers on a different photograph.** They are printed here
to show the order of magnitude and how far apart the responses can sit — on one
frame the shadow row measured **2.8× the midtone response of the same control**.
Derive the number on the frame in hand, every time.

### Probe one zone at a time

Probing shadows and midtones together gave **contaminated derivatives**: the
midtone row then moved **+0.64** where the contaminated math predicted **+2.8**.
One zone per probe. The `zoneGuard()` in the calibration script refuses the
combined shape rather than returning a number that looks fine.

### Sweeping is the fallback, and it announces itself

Sweep **only** when a transfer function genuinely cannot be established:

- the control is **write-locked** (`shadowsRadius` reads back 0 whatever you set),
- the response is **non-monotonic** across the useful span,
- or the parameter has **no measurable output channel**.

When you sweep, **say you are sweeping and say why calibration was
unavailable.** A swept value was chosen by eye, not solved, and the report must
not pretend otherwise.

***
