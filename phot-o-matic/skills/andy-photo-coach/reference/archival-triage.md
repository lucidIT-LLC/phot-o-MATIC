# Andy — archival triage

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Archival Triage — the cull lane, stills AND video

**The operator named this lane himself, and his words are the spec:**

> *"for archival like this — so helpful. just telling me what to trash you'll
> never get a good shot out of it is great."*

**That is permission to be decisive, and it is the job.** A cull is not a
gentle ranking. The value is in the **pitch** list — the frames and clips that
will never be worth an hour, said plainly, with the reason.

**His keep standard, verbatim from an earlier session:**

> *"i'd take one fantastic over — you know.."*

**One fantastic frame beats nine adequate ones.** Do not pad a keep list to
look thorough. A shoot that yields two keepers yielded two keepers.

### The working shape of a cull

Measured practice from the 43-file cull of `Photography/DJI_001`, 2026-09-12:

1. **Measure everything first.** Every file, not a sample. The cheap reads —
   dimensions, clipping, sharpness proxy, telemetry — before any judgment.
2. **Contact-sheet it.** You are a photographer; look at the set as a set.
   Patterns across a shoot are invisible one file at a time.
3. **Group by shoot**, not by folder. Filenames and timestamps cluster;
   folders lie (§ IPTC provenance rule 3 — the stamped hour can be wrong).
4. **Give a keep/pitch list with a STATED REASON PER ITEM.** Not a score. A
   reason. "Pitch: 1/8000 at 60fps, strobes on every pan, unfixable" is
   actionable. "4/10" is not.
5. **MOVE TO TRASH. NEVER HARD-DELETE.** This is not a preference. The
   operator reviews the pitch list *after* the move, and a hard delete removes
   his ability to disagree with you. **Recovery-aware or not at all.**

### Video criteria — measured, and new to Andy in 2.3.0

Andy had **no video criteria at all** before this release. These are from
#492 §I, all **measured** on the `DJI_001` cull.

**DJI `.SRT` sidecars are a per-frame telemetry track, and they are richer than
the MP4's own metadata.** Fields carried: `iso`, `shutter`, `fnum`, `ev`,
`color_md`, `focal_len`, `lat`/`lon`, `rel_alt`/`abs_alt`, color temperature.

> **READ THE WHOLE DISTRIBUTION, NOT FRAME 1.** A clip's opening frame is the
> least representative thing in it — the aircraft is often still settling and
> the exposure still converging. Read across all frames and report the spread.

**Video shutter must be about 1/(2 × fps).** That is the 180° shutter rule and
it is the single highest-yield criterion in the lane.

| Measured | Value |
|---|---|
| Clip frame rate | **60 fps** |
| Correct shutter | **~1/120** |
| Measured shutter | **1/8000, held across all 6364 frames** |
| Error | **66× too fast** |
| Verdict | **strobes panned terrain. UNFIXABLE IN POST.** |
| Condemned by this one criterion | **3.5 GB** |

**A too-fast shutter is not a look, it is damage** — each frame is individually
sharp and the motion between them is a stutter, and no grade, warp or frame
blend puts the missing motion blur back. **Say "unfixable" and mean it.**

**Byproduct files, both safe to pitch:**

| Extension | What it is |
|---|---|
| `.LRF` | **Low-res edit proxy.** The real clip is the MP4 |
| `.af` | **Autofocus data.** Not media at all |

Neither is a deliverable and neither is a backup. They are what the aircraft
left behind.

***
