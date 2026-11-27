# Andy — the Affinity instrument

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Contents

- 9. The Affinity Instrument — measured, not assumed
  - 9.0 LOAD THE TOOLKIT. DO NOT RETYPE THE API.
  - 9.1 CHECK THE SOURCE BEFORE YOU GRADE ANYTHING
  - 9.2 ALWAYS TAKE A SETTLE READ
  - 9.3 ADDRESS DOCUMENTS BY `sessionUuid`, NEVER `app.documents.current`
  - 9.4 The bulk read IS the design. Grid sampling is the fallback.
  - 9.5 The five silent-failure rules
  - 9.6 Scales as they actually return, not as their names imply
  - 9.6b The 8-bit banding budget
  - 9.7 Vendor parameter ranges — stop guessing magnitudes
  - 9.8 Reading the numbers
  - 9.9 Clipping is always exact, never sampled
  - 9.10 WHEN THE SIGNS DISAGREE, NO GLOBAL MOVE WORKS
  - 9.11 LEVELS IS THE RANGE TOOL
  - 9.12 The tools that are WRONG for a flat image
  - 9.13 ShadowsHighlights filter — the signs, and the locked knob
  - 9.14 Masking works — and it is the answer to sign disagreement
  - 9.15 Crop — and the two things that will fool you
  - 9.16 Export — three arguments, and the bug that is narrower than recorded
  - 9.17 Two more things that are not optional
  - 9.18 The hint pool lies — it is data, not authority
  - 9.19 ADDING A LAYER — the sequence, and the two methods that do not exist
  - 9.20 HSLShift — the hue-selective instrument
  - 9.21 The export sandbox is NOT the agent's filesystem

## 9. The Affinity Instrument — measured, not assumed

Everything in this section was **measured**, on 2026-09-11 and 2026-09-12,
against the live SDK, and is recorded in **decisions #489, #491 and #492**.
Where something is inferred or untested it says so in those words. Do not soften
any of it into prose; these are the facts that make the difference between a
correct reading and confident nonsense.

**Two things in here contradict what 2.2.0 shipped, and both are marked where
they sit** — the `magentaGreen` sign (§9.8, task #719) and the canvas-resize
claim (§9.15). **One thing contradicts decision #492 itself** and is marked
there too (§9.7, ColourBalance reachability). **When this file disagrees with a
decision record, the measurement wins and the disagreement gets written down.**
Neither gets to be quietly right.

### 9.0 LOAD THE TOOLKIT. DO NOT RETYPE THE API.

**Four instruments exist in the Affinity script library. Call
`list_library_scripts` and load them before you write a line of script.**

> **LOAD THE `v2` MEASUREMENT SCRIPTS. THE UNSUFFIXED ONES ARE DEFECTIVE.**
> Task #719: `Photo Measure` opened with `app.documents.current`, violating
> §9.3 — the rule stated by this very file. **Four documents were open** when
> Andy first loaded it; it would have measured whichever window was last
> clicked and printed the result under the target's name. Checking `Photo
> Compare` for the same pattern **found it there too**, one line further down,
> choosing the subject of the region map. Both are fixed in `v2`, which takes
> an explicit `TARGET_UUID` and **blocks rather than guesses** when several
> documents are open.
>
> **The old titles still exist in the library and cannot be overwritten** — the
> Affinity library refuses a duplicate title and exposes no delete. **The
> operator must remove the two unsuffixed scripts in Affinity's own script
> manager.** Until then, read the title before you run it.

| Script | What it is |
|---|---|
| **`Photo Measure v2 — Tonal Distribution + Lab Cast Report`** | Full-frame tonal distribution, exact clipping counts, global / near-neutral / per-zone Lab cast, with a runtime calibration gate and a scale guard that **block** rather than degrade. Read-only. **Use v2.** |
| **`Photo Compare v2 — Region Cast Map + A/B Across Open Documents`** | The verification half. Delta between two open documents, sign-flip detection (that is the purple failure), and a 3×3 region cast map. Read-only. **Use v2.** |
| **`Photo Grade — Calibrated Adjustment Toolkit`** | **The whole verified write surface, as working code.** `byUuid()`, `settle()`, `makeAdj()`/`setFields()` handling the two-level nested `values` and `masterParameters` reassignment, `addStack()`, `levels()`, the mask recipe, `crop()`, `exportFile()`, `frameBuffer()` with a scale guard, and a Lab calibration gate. Ships a `SELFTEST()` that needs no document. |
| **`Photo Calibrate — Transfer Function Probe`** | §5 as runnable code: `probe()`, `perUnitFrom()`, `solveFor()`, `solveFromProbe()`, a `zoneGuard()` that refuses multi-zone probes, a noise-floor check, vendor-range clamping that reports rather than truncates, and a `sweepFallback()` that refuses to run without a written reason. |

**The rest of §9 is the judgment you need before you decide anything — read it.
The call signatures are in the toolkit; load them rather than retyping them
from here.** Every signature below was learned by failing at it first, and the
toolkit is the version that was proven to run: `SELFTEST()` returned **12 pass,
0 fail** with no document and **15 pass, 0 fail** including the live half on
2026-09-12.

They extend; they do not get replaced. **Durability is the point** — the
2026-09-10 session's work survived only in a chat log, and that is the defect
#486 was opened to close.

### 9.1 CHECK THE SOURCE BEFORE YOU GRADE ANYTHING

**Ask for the RAW or the original before you spend one measurement on a
derivative.** Measured 2026-09-12 on the Palm Desert frame: the operator's own
submission-ready JPEG had **20.44% of its pixels carrying a clipped channel**
where the HEIC original had **0.00%** — and the JPEG's crop had discarded **6.7
megapixels** of frame.

Grading the JPEG would have been careful work on damage that was already done
and on a frame that had already been thrown away. Ask first. It costs one
sentence.

### 9.2 ALWAYS TAKE A SETTLE READ

**Discard the first measurement after any document change and use the second.**

Skipping this produced, in one session, a **NaN** and a false **"NOT MASKED"**
verdict on a mask that was in fact working, and read a\* **-4.517** where the
settled value was **-5.194**. The buffer is stale for one read. `settle()` in
the toolkit is two lines and removes the whole class of error.

### 9.3 ADDRESS DOCUMENTS BY `sessionUuid`, NEVER `app.documents.current`

`app.documents.current` switches the moment the operator clicks another window.
**Two adjustment layers landed on the wrong photograph** because of it.

Confirmed live again on 2026-09-12 while building the toolkit: `app.documents.all`
went from 1 to 2 mid-session and `current` moved to the newly opened document
with no signal of any kind. Capture the `sessionUuid` once and look it up on
every call — `byUuid()` in the toolkit does exactly that and throws a listing of
what *is* open when it cannot find yours.

### 9.4 The bulk read IS the design. Grid sampling is the fallback.

```js
const eng = NodeRenderingEngine.createDefault(doc.currentSpread, doc.format);
const arr = new Uint16Array(eng.createCompatibleBuffer(true).buffer); // RGBA16
```

`RasterObject.createCompatibleBuffer(true).buffer` returns **a real
`ArrayBuffer`**. Measured: 292 MB, **all 36,578,304 pixels** of an 8064×4536
16-bit document scanned in **188 ms**, values **byte-identical to `readPixel`**.
Read the whole frame. It is cheap.

`readPixel(x, y)` costs **~4.7 microseconds** steady state. A 400-point grid is
about **2 ms**, not 4 seconds. Convergence speed is not an engineering
constraint here.

**This corrects a briefing that was wrong.** Andy was told readPixel is
per-pixel with no bulk read, so the instrument "must sample a grid," and that a
read costs ~10 ms. Both false — the bulk read simply is not in
`pixelaccessor.js`, which was the only file read before the claim was made.
Decision #487 repeats the same false constraint about Affinity and is wrong on
that half; its Pixelmator half was independently measured and stands.

**Grid sampling remains the fallback** when the bulk buffer is unavailable.
Default **160 × 160 = 25,600 jittered samples**. Measured convergence on an
8064×4536 frame: a\*/b\* stabilize to ±0.1 by 6,400 samples and ±0.05 by 25,600,
with the 25,600-sample estimate tracking exact ground truth to **0.03**;
jittered and regular grids agreed within 0.03, so no aliasing on that image.

### 9.5 The five silent-failure rules

Each of these returns **plausible wrong data rather than an error**. That is
what makes them dangerous: nothing fails, and the reading is garbage.

1. **Render `doc.currentSpread`.** Not `doc.layers.first`. A photograph's top
   `PhysicalNode` has **no `rasterInterface` at all**.
2. **Pass `doc.format`, and nothing else.**
   `NodeRenderingEngine.createDefault(node, fmt)` silently returns a fully
   allocated, correctly sized, **all-zero alpha-0 bitmap with no error** whenever
   `fmt` does not match the document format. This cost four iterations of
   reading zeros before anyone noticed.
3. **Use `createCompatibleBuffer`.** The `createCompatibleBitmap` and `copyTo`
   variants return empty from an engine.
4. **Never read an adjustment child node's `rasterInterface`.** Those *do*
   expose one, at the right dimensions — but at **format 7 = M16**, which is the
   adjustment's single-channel **mask**. Reading that and calling it the image
   produces confident nonsense.
5. **Never verify a `ColourBalance` write with `JSON.stringify`. Index it.**
   `ColourBalanceAdjustmentParameters.values` is a **native indexable
   container, not a JS array**, and it does not serialize. **Measured
   2026-09-12:** `JSON.stringify(values)` returns **`{}`**,
   `Object.keys(values)` returns **`[]`**, and `values.length` is
   **`undefined`** — *while the values are present and correct*. In the same
   run, after writing a 3-array, `values[0].cyanRed` read back **0.10999**,
   `values[1].magentaGreen` **-0.21999** and `values[2].yellowBlue` **0.33000**.
   The container reads empty **whatever it holds**. `values[i].field` is the
   only honest readback.

> **This one has already cost a false finding, which is why it is a rule.**
> Decision **#492 §A3** concluded from a `{}` readback that the write "succeeds
> silently and does nothing" and that **ColourBalance is unreachable from
> script**. That conclusion was **disproven by direct measurement on
> 2026-09-12** while certifying this release — see §9.7. The empty readback is
> a **serialization gap, not an empty value**. A control that this file was
> about to declare dead is alive and was being used successfully all along.
> **Rule 5 is the general form: a readback that cannot represent the data is
> not evidence of absence.**

### 9.6 Scales as they actually return, not as their names imply

| Reader / API | Returns |
|---|---|
| `PixelReaderRGBA16.readPixel` | `{r,g,b,alpha}` **0–65535** |
| `PixelReaderLABA16.readPixel` | `l` **0–65535**, but `a`/`b` **SIGNED** — empty reads come back at **-32768** |
| `Colour.laba16` | **D50 ICC.** `l = L* × 655.35`; `a`/`b` = `value × 257 + 128` — so **neutral is 128, NOT 0** |
| `PixelReaderRGBA8` | **NOW TESTED against real content** (2026-09-12; it was labeled untested in 2.1.0). `Colour.createRGBA8(...).laba16` uses the **same encoding** as the 16-bit path — neutral at **128**. |

**Normalize to float 0–1 at every helper boundary** so a caller can never mix an
8-bit scale with a 16-bit one. The shipped instruments do this and carry a
**scale guard** that blocks when 16-bit-declared data never exceeds 255.

**Derive the Lab encoding at runtime; never assume it from an API name.** The
calibration gate round-trips known colors through the vendor, solves for scale
and offset, checks self-consistency across five colors (measured spread 0.117),
then validates the fast path against `Colour.laba16` on 1,500 real pixels
(measured max error 0.0047 against a 0.05 threshold). It **blocks** on failure
rather than degrading. Verified again 2026-09-12: white round-trips to
`{l:65535, a:128, b:128}`, black to `{l:0, a:128, b:128}`.

### 9.6b The 8-bit banding budget

An 8-bit file has 256 levels per channel and an aggressive Levels stretch spends
them. **Track the budget on every 8-bit grade:**

- **Levels used** of 256.
- **Comb gaps** — empty levels left between occupied ones.
- **Longest run** of adjacent empty levels. **A run of 1 is tolerable. A run of
  2 or more is a visible step in a smooth sky.**

Report it as a number, the way you report clipping. Banding is the failure that
looks fine at fit-to-screen and ruins the print.

### 9.7 Vendor parameter ranges — stop guessing magnitudes

Guessing the magnitude is the documented failure from the 2026-09-10 session.
**Ground truth is `struct_ranges.min.json`.** The advertised doc topics
`adjustment_ranges` and `filter_ranges` **both return "File not found"** — they
are listed and they do not exist. Do not chase them.

| Parameter | Measured range | Note |
|---|---|---|
| `Exposure` | **[-20, 20]** | **not** [-1, 1] — this is the one that burns you |
| `ColourBalanceValues.cyanRed` | [-1, 1] | |
| `ColourBalanceValues.magentaGreen` | [-1, 1] | negative = toward **magenta** |
| `ColourBalanceValues.yellowBlue` | [-1, 1] | |
| `ColourBalanceAdjustmentParameters.values` | **indexable container, NOT an array** | **`[0]` Shadows, `[1]` Midtones, `[2]` Highlights.** Reads back `{}` — index it (§9.5 rule 5) |
| `Clarity.strength` | [-1, 1] | **negative softens** — not 0..1 |
| `ShadowsHighlights` | [-2, 2] | the *adjustment*; the *filter* fields have no declared range |
| `UnsharpMask.factor` | [0, 4] | |
| `UnsharpMask.radius` | [0, 1024] | |
| `UnsharpMask.threshold` | [0, 1] | |
| `HSL.hueShift` | **[-π, π]** | radians — **the DECLARED range. It does not predict the output move.** See §9.20 |
| `Levels` black/white/outputBlack/outputWhite | [0, 1] | |
| `Levels` `gamma` | [0, 2] | **inverse — above 1 DARKENS.** See §9.11 |

#### `ColourBalanceValues` — how you actually build one

**All four lines measured 2026-09-12** while certifying this release, against
the live SDK with no document open:

- **`ColourBalanceValues.create` is undefined.** Do not call it.
- **`new ColourBalanceValues()` WORKS** and returns
  `{yellowBlue: 0, magentaGreen: 0, cyanRed: 0}`. Note this is the **exact
  inverse** of `AddChildNodesCommandBuilder`, where `create()` works and `new`
  throws `Invalid handle` (§9.17). **There is no house rule here — check each
  class.**
- **A plain object is accepted**, both into an element (`values[1] = {...}`)
  and as a whole (`values = [...]` or `values = {0:…, 1:…, 2:…}`). All three
  shapes were written and indexed back correctly. `setFields()` in the toolkit
  uses the element form.
- **ColourBalance is reachable, writable and usable from script.** The
  three-zone `values` container is exactly the instrument §9.10 calls for when
  the zone signs disagree.

> **Decision #492 §A3 says the opposite — that ColourBalance is unreachable —
> and #492 is wrong on that point.** It is corrected here rather than shipped,
> because shipping it would have retired a working control on the strength of a
> `{}` that means nothing (§9.5 rule 5). The rest of #492 held up under
> re-measurement; this item did not. **#492 is otherwise authority for this
> section — treat §A3 alone as superseded**, and see the §14 note on what is
> owed back to the decision record.

### 9.8 Reading the numbers

**Judge the cast on the NEAR-NEUTRAL line, never the global mean.** A blue sky
drags global b\* to -15 as **subject color**, not as a cast. The instrument
reports both; the near-neutral line is the one that means something.

| Reading | Verdict |
|---|---|
| \|a\*\|, \|b\*\| < 1 | neutral |
| 1 – 3 | slight |
| 3 – 6 | clearly visible |
| > 6 | strong |

- a\* is the **green(−) / magenta(+)** axis. b\* is **blue(−) / yellow(+)**.
- **Negative a\* is green**, and you cancel it by moving `magentaGreen`
  **NEGATIVE**. Negative `magentaGreen` moves the image toward **magenta**,
  which is what raises a\*. Positive `magentaGreen` moves it toward green.
- **Color Balance runs far stronger per unit than it feels** — measured at
  **109.26 a\* per unit** globally on one frame. Do not eyeball the first value;
  **calibrate it** (§5).

> **This sentence shipped inverted in 2.2.0 and is corrected here (task #719).**
> It read "cancel it by moving `magentaGreen` **positive**," which would push a
> green-cast frame **further green** — the exact failure §9.10 exists to
> prevent. Two independent measurements settle the direction: a probe of
> `magentaGreen` **-0.05** moved near-neutral a\* from **-5.194 to +0.269**
> (session #227, **measured**, a partial derivative of **-109.26 a\* per unit**),
> and the SDK hint pool's experimentally-rendered entry agrees.
>
> **Note what this file did to itself, because it is the real lesson.** §9.7
> already carried the correct direction — "`magentaGreen` negative = toward
> magenta" — one screen above the inverted sentence. **Two sections of the same
> document disagreed, and every verifier passed.** `verify-pack` checks
> structure, and a `SELFTEST` checks the script it ships with; **nothing in the
> gate reads doctrine for internal contradiction.** When two sections of this
> file disagree, neither is authority — go and measure. Andy caught this one
> only because §5 made him calibrate instead of trusting the text.

### 9.9 Clipping is always exact, never sampled

Sample the cast if you must. **Never sample the clipping.** Clipped regions are
spatially **clustered**, so sampling undercounts them: measured, crushed-black
read **0.362% at 102k samples versus 0.494% at 490k — a 25% undercount.**
Sampling clipping would have been quietly wrong, which is the worst kind of
wrong. Count clipped pixels over the full buffer, always.

### 9.10 WHEN THE SIGNS DISAGREE, NO GLOBAL MOVE WORKS

**This is the most important thing in this file. Check it BEFORE proposing any
global correction.**

If the per-zone rows disagree in sign, or if the region map disagrees in sign,
**a single global Colour Balance move cannot fix both.** It must neutralize one
and overshoot the other. There is no value that works.

Measured on the real file, 2026-09-11:

| Zone | near-neutral a\* | reads as |
|---|---|---|
| Shadows | **+5.095** | magenta |
| Midtones | **-3.995** | green |
| Highlights | **-4.308** | green |

And spatially: green concentrated in the **top** of the frame (a\* -4.7 to -5.9)
while the **bottom** was already neutral-to-magenta (+0.7 to +1.1).

**That is mechanically why the 2026-09-10 session went purple.** A global
magenta push overshot the shadows while leaving the midtones green. It was
invisible to "does it look right now," and no amount of looking harder at a
rendered JPEG would have revealed it.

**What to do instead:**
1. Run the measurement. Read the per-zone rows and the 3×3 region map.
2. If the signs agree — one global move, **calibrated** (§5), then re-measure.
3. If the signs **disagree** — say so out loud, and reach for a **masked or
   gradient-limited adjustment** (§9.14), or per-zone `values[0..2]` on Colour
   Balance, which is exactly what the 3-array is for. **Calibrate each zone
   separately** — combined probes contaminate the derivatives (§5).
4. Re-measure. **An overshoot shows up as a sign flip.** A correction that
   worked moves near-neutral a\*/b\* *toward* 0.

*Caveat recorded honestly in #489: the two files compared that day were
different frames shot 20 s apart, so that was a cross-image comparison, not a
true before/after. Say that kind of thing when it applies.*

### 9.11 LEVELS IS THE RANGE TOOL

When an image is flat and you need to open the tonal range, **reach for Levels.**
Its parameters live under `masterParameters`:

| Field | Range | Note |
|---|---|---|
| `blackLevel` | [0, 1] | input black point |
| `whiteLevel` | [0, 1] | input white point |
| `gamma` | [0, 2] | **INVERSE TO INTUITION — values ABOVE 1 DARKEN** |
| `outputBlackLevel` | [0, 1] | **this is what stops a black-point stretch from crushing** |
| `outputWhiteLevel` | [0, 1] | |

**`outputBlackLevel` is the one people miss.** Measured: **122,792 crushed
pixels at 0, falling to 28,278 at 0.10.** If a black-point stretch is crushing
shadows, lift the output black rather than backing off the stretch.

Defaults read back live 2026-09-12: `blackLevel` 0, `whiteLevel` 1, `gamma` 1,
`outputBlackLevel` 0, `outputWhiteLevel` 1.

### 9.12 The tools that are WRONG for a flat image

All three were tried on a flat frame in the 2026-09-12 session and all three
made it worse. This table exists so nobody spends those tokens again.

| Tool | What it actually did | Why |
|---|---|---|
| `Exposure` | **SHRANK** the tonal range from **172 to 123** | It scales rather than stretching |
| `Contrast` | **Brightened an already-bright image** | Its pivot sits near mid, and the median was high at **184/255** — so the mass of the image is above the pivot |
| `ToneStretch` | **Collapsed the image to a tonal range of 1** | It is not a tonal stretch, whatever the name suggests |

**Reach for Levels.** See §9.11.

### 9.13 ShadowsHighlights filter — the signs, and the locked knob

- **`shadowsRadius` is WRITE-LOCKED.** Every value reads back **0**. Do not
  spend a probe on it. `shadowsStrength` and `shadowsRange` are the working
  knobs; the same applies on the highlights side.
- **`highlightsStrength` NEGATIVE recovers highlights.** Measured: **109,154
  clipped pixels down to 49,387.** **Positive makes it worse.**
- **`shadowsStrength` POSITIVE lifts** shadows.

Related, measured on the waterfall: a **-0.20 exposure** move recovered **all
49,223 clipped highlight pixels** on that frame. Exposure is wrong for opening a
flat range (§9.12) and right for pulling a blown highlight back — the tool is
not good or bad, it is right or wrong for the job.

Field names, read back live: `version`, `shadowsStrength`, `shadowsRange`,
`shadowsRadius`, `highlightsStrength`, `highlightsRange`, `highlightsRadius`.
These fields have **no declared range** in `struct_ranges.min.json`, so
calibrate them (§5) rather than assuming.

### 9.14 Masking works — and it is the answer to sign disagreement

```js
doc.setRasterSelectionFromPolygon(
  curve.generatePolygon(0.1),
  RasterSelectionLogicalOperation.New,
  true,            // antialias
  featherPx
);
// add the adjustment WHILE the selection is live — it is masked to it
doc.rasterDeselect();
```

Build the curve with `Curve.create()` and `appendNode({position, type})`.

**An adjustment added while a raster selection is live IS masked to it** —
measured **2.9% leakage**. On the storm frame a masked sky pass moved the sky
a\* by **3.125** while the ground moved **0.077**. Deselect afterward.

Masking also changes the transfer function: the same control measured **72.83
a\* per unit inside the mask** against **109.26 global**. **Calibrate inside the
mask**, not outside it.

### 9.15 Crop — and the two things that will fool you

`Document.setSpreadSizeWithAnchor(spreadNode, w, h, SpatialAnchor.TopCentre)`.

**`doc.currentSpread` works directly as `spreadNode`** — measured 2026-09-12.
The old instruction to take it "by iterating `doc.spreads`" was unnecessary;
iterating still works, so the toolkit's `crop()` is not wrong, just longer than
it needs to be.

1. **The rendering engine and export DO reflect a canvas resize** —
   **measured 2026-09-12**, correcting 2.2.0, which said they do not. After
   `setSpreadSizeWithAnchor(doc.currentSpread, 3777, 2722, SpatialAnchor.TopLeft)`:
   `doc.widthPixels`/`heightPixels` read **3777×2722** immediately,
   `NodeRenderingEngine.createDefault(doc.currentSpread, doc.format)` reported
   **3777×2722**, and the **exported JPEG measured 3777×2722**.
   **BOUNDARY, and keep it:** the MCP **`render_spread` tool itself was not
   re-called after the crop**, so that specific claim is **untested today, not
   disproven**. The engine and the export are proven; the tool is unmeasured.
   If you need to know, call it and record the answer.
2. **A script crop is effectively ONE-WAY. This claim STANDS —
   it was NOT retested in the 2.3.0 session**, and an untested claim is not a
   weakened one. Measured twice, 2026-09-12: the
   resize *does* register an undo entry ("Page Properties Changed") and
   `doc.undo()` *does* consume it — `canUndo` goes true to false — **without
   restoring the size.** Confirmed with a settle read and again from a fresh
   script context, so it is not caching. An older SDK hint claims undo reverts a
   resize; from script, it does not. **Decide the crop before you make it, or
   work on a duplicate.**

*Honest caveat: the size did return to the original once between runs by a means
not performed from script — most plausibly the operator using the app's own
undo. That is unconfirmed and is recorded as unconfirmed.*

### 9.16 Export — three arguments, and the bug that is narrower than recorded

`FileExportOptions` and `FileExportArea` come from `require('/document')`.
`FileExportOptions.createWithPresetName('JPEG (High quality)')` plus
`FileExportArea.createForWholeDocument(doc)`, then `doc.export(path, opts, area)`
— **three arguments**. (`Document.prototype.export` reports arity 4; three is
the shape that was used successfully.)

**CORRECTION TO THE RECORDED BUG.** The dark / purple export corruption affects
**only `Document.load()`-ed documents.** A natively-opened document exported
**clean** in the 2026-09-12 session, verified by measuring the exported pixels
against the in-app buffer. For a `Document.load()`-ed document neither
`render_spread` nor export can be trusted — but its **parameter reads are
accurate**, so verify by data rather than by pixels.

The Affinity sandbox reaches the **Desktop only** (`app.userDesktopPath`).

### 9.17 Two more things that are not optional

- **`AddChildNodesCommandBuilder.create()` — never `new`.** `new` throws
  `Error: Invalid handle`. Verified again 2026-09-12. **The full sequence, and
  the two builder methods that do not exist, are in §9.19.**
- **`doc.executeCommand()` returns `undefined` on this build**, so `cmd.newNodes`
  throws. **Read `target.children`** to find what you just added.
- **`Levels` and `Curves` `createDefault(doc)` require a `DocumentHandle`.**
  Every other adjustment definition takes `createDefault()` with no argument.
  Calling Levels with none throws
  `TypeError: Cannot read properties of undefined (reading 'handle')`.
- **The `parameters` getter returns a fresh copy on every access.** Mutating it
  in place is a silent no-op. Read once, mutate the local, write it back — and
  for `values` / `masterParameters`, do it **two levels deep**.
- **An already-placed adjustment node cannot be edited by reassignment** — that
  is also a silent no-op. `doc.undo()` the insertion and add a fresh definition.

All of this is implemented in `Photo Grade — Calibrated Adjustment Toolkit`.
Load it.

### 9.18 The hint pool lies — it is data, not authority

`search_sdk_hints` returns **other sessions' generated text**, and it **reads
like a confident answer.**

| The pool asserted | Measured reality |
|---|---|
| image layers are linear float, **format 9**, read via `PixelReaderRGBAuf` | **format 1 (RGBA16)**, `isLinear` **false**, gamma **2.202** |
| **0.7 µs** per pixel read | **4.7 µs** |
| 5 MP takes **15–20 seconds** | **36.6 MP in 188 ms** |
| `doc.undo()` reverts a `setSpreadSizeWithAnchor` | it consumes the undo entry and **leaves the size cropped** (§9.15) |
| the dark/purple export bug is an export bug | it is a **`Document.load()`** bug (§9.16) |

Treat every hint as a lead to verify, never as a fact to cite. When you verify
one, `add_sdk_hint` the corrected version so the next session inherits the truth
instead of the guess — **including when the thing you are correcting is your own
earlier hint.**

### 9.19 ADDING A LAYER — the sequence, and the two methods that do not exist

**Measured 2026-09-12** (#492 §B), re-confirmed against the live SDK while
certifying this release.

**`AddChildNodesCommandBuilder.create()` has NO `setTargetParent` and NO
`addNodeDefinition`.** Both read back `undefined`; calling the first throws
*"setTargetParent is not a function."* If you reach for either, you learned the
API from somewhere that was guessing. The builder carries **56 `add*` methods**
and the one you want is named for your node type.

The sequence that works:

```js
const def = N.LevelsAdjustmentRasterNodeDefinition.createDefault(doc); // params live here
setParamsOnDef(def);                                                   // see the table below
const b = AddChildNodesCommandBuilder.create();                        // create(), never new
b.setInsertionTarget(doc.layers.first);
b.setInsertionMode(InsertionMode.Inside_AtFront);
b.addLevelsAdjustmentRasterNode(def);   // the DEFINITION, not the parameters
doc.executeCommand(b.createCommand());  // returns undefined — read target.children
```

**The typed adders take the NodeDefinition, not the parameters object.** Pass
parameters and you get *"expected LevelsAdjustmentRasterNodeDefinitionHandle."*

**`LevelsAdjustmentParameters.createDefault` DOES NOT EXIST**, and neither does
`.create` on it. Measured the same way: `BrightnessContrastAdjustmentParameters`,
`SelectiveColourAdjustmentParameters` and `HSLShiftAdjustmentChannelParameters`
have **neither** `.create` nor `.createDefault`. **You do not build a parameters
object and hand it to a node — you build the node definition and set its
parameters.** (`CurvesAdjustmentParameters.create` *is* a function, which makes
it the exception; that is not a reason to assume the others are.)

#### The write path differs by type. Two of them fail quietly.

| Definition | How you write parameters |
|---|---|
| `Levels` | `def.setParameters(p)` — `createDefault(doc)` **needs the document** |
| `Curves` | `def.setParameters(p)` — `createDefault(doc)` **needs the document** |
| `SplitToning` | `def.setParameters(p)`, and a **plain object is accepted** |
| `ColourBalance` | `def.setParameters(p)` — verify by **indexing** `values[i]`, never `JSON.stringify` (§9.5 rule 5) |
| `HSLShift` | **NO `setParameters`.** Assign `def.parameters = pp` instead |

- **`HSLShiftAdjustmentRasterNodeDefinition.setParameters` is `undefined`** —
  measured. Assign the property. And **`def.parameters` on HSLShift enumerates
  empty**, so *readback cannot verify an HSLShift write at all.* **Verify it by
  measuring the render.**
- **`CurvesAdjustmentParameters.masterSpline` is a COPY ON READ and a SETTER ON
  ASSIGN.** Mutating the object the getter hands you applies **nothing**.
  Measured: `pointCount` went **2 → 5** on the local object, the layer was
  added, and **mean L\* moved 0.00**. You must assign it back:

  ```js
  const sp = cp.masterSpline;        // a copy
  sp.replaceOrInsertPointXY(0.5, 0.58);
  cp.masterSpline = sp;              // WITHOUT THIS LINE, NOTHING HAPPENS
  ```

  Spline members: `replaceOrInsertPointXY`, `insertPointXY`, `getPoint`,
  `pointCount`, `isLinear`, `findPointXY`, `removePoint`, `clear`. **Domain
  0..1.**

**Both of those are the §9.17 copy-on-read rule wearing a different hat.** A
"layer added, nothing changed" result is almost always a write that landed on a
copy.

### 9.20 HSLShift — the hue-selective instrument

**This is the tool for "warm the timber without touching the foliage."** Where
§9.10 says sign disagreement needs a mask, HSLShift is the option that needs no
mask at all — it selects by **hue**, not by region. All figures **measured
2026-09-12** (#492 §D) on the Poole's Mill covered-bridge frame.

**Six channels, indices 0–5. Index 6 or above returns `INVALID_ARGS`.**
`getChannelColourRange(i)` returns `rampUpBegin` / `rampUpEnd` /
`rampDownBegin` / `rampDownEnd` **in radians**. Decoded to degrees:

| Index | Channel | Plateau | Ramps |
|---|---|---|---|
| 0 | Red | **345–15°** | 30° either side |
| 1 | Yellow | **45–75°** | 30° either side |
| 2 | Green | **105–135°** | 30° either side |
| 3 | Cyan | **165–195°** | 30° either side |
| 4 | Blue | **225–255°** | 30° either side |
| 5 | Magenta | **285–315°** | 30° either side |

#### The technique, and it is the part that transfers

**Choose the channel by MEASURING the subject's RGB-hue histogram. Never by
naming the color you see.** On the measured frame those two methods disagreed
completely:

- Foliage that reads to the eye as **green** sat **80.8% in channel 1
  (YELLOW, 45–75°)** and **0.0% in channel 2 (Green)**, mean hue **68.6°**.
  That is the numeric definition of chartreuse, and it is why **ch1 was the
  lever**. Reaching for the green slider would have moved nothing.
- Bridge timber that reads as **brown** measured RGB hue **230–240° — BLUE** —
  because it was lit by **skylight**. **Ch4 was its lever.**

Sample the subject, build the hue histogram, read which plateau holds the mass.
The frame will tell you. Your eye will not.

#### Selectivity, measured

Channel 4 `saturationShift` **-0.6397** moved the timber b\* from **-6.37 to
-2.00** — target **-2.00**, **miss 0.00** — while everything else held:

| Region | Move |
|---|---|
| Timber (the target) | b\* **-6.37 → -2.00** |
| Foliage | **0.00** (a\* -21.15 → -21.15, b\* 33.58 → 33.58) |
| Stone | **0.04** |
| Water | **0.01** |

**That is what a hue-selective adjustment buys you**, and it is why it beats a
mask when the subject is defined by color rather than by place.

#### The non-linearity — this WILL cost you a pass if you skip it

**A small probe UNDER-STATES a hue-channel response, and a value solved from it
OVERSHOOTS.** Measured:

| | Value |
|---|---|
| Slope from a **+0.05 probe** | **-37.3 °/unit** |
| True local slope through **two real points** | **-46.76 °/unit** |
| Difference | **25%** |
| Landed from the small-probe solve | **93.38°** against a target of **88.0** — a **27.8% miss** |
| Landed after **re-deriving from two measured points** | **87.08°** — a **0.92° miss** |

**So on a hue channel, budget two real points before you solve.** §5's
ten-percent re-derivation rule is not optional here; it is the normal path.

> **HYPOTHESIS, NOT MEASURED** — offered as a lead, not a fact. A hue-selective
> channel **moves its own selection**: as the subject rotates in hue, the
> fraction of it sitting on the **plateau** versus on the **ramp** changes, so
> the effective gain changes underneath you. That would explain the direction
> of the error — a small probe never leaves the plateau. **Nobody has tested
> it.** If you test it, record the result.

**And note the declared range does not help you here.** `HSL.hueShift` declares
**[-π, π]** radians (§9.7). That is the input bound. It tells you nothing about
how far the output moves, which is the number you actually need — and the
measured °/unit above is the only way to get it.

### 9.21 The export sandbox is NOT the agent's filesystem

**Affinity's export grants and your own file access are different things, and
they do not overlap the way you would expect.** Measured 2026-09-12 (#492 §G):

| `doc.export()` target | Result |
|---|---|
| The session **scratchpad** | **PERMISSION_DENIED** |
| The directory holding **the open document itself** | **PERMISSION_DENIED** |
| **`~/Desktop`** (`app.userDesktopPath`) | **OK** |

The second row is the surprising one: **Affinity will not export next to the
file it already has open.** Do not read a denial as a broken path or a bad
filename.

**The route: export to the Desktop, then move it with the shell.** Two steps,
and the second one is outside Affinity entirely. Tell the operator where the
file landed if you leave it there.

***
