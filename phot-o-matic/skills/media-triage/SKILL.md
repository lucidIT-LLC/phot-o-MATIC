---
name: media-triage
description: Walk a folder of the operator's footage or photographs and produce a keep/pitch verdict. Use for culling a camera card, finding usable segments in long clips, or reviewing a shoot. Carries the measurement-first method, the HLG handling, and the disposal rules — including one that failed silently and destroyed 7.6 GB.
---

# Walking a folder of the operator's media

**The keep/pitch verdict IS the deliverable.** Not a list of files, not a count
of candidates — a verdict, with the reason, so the tell is learned.

## The order, and it does not vary

**1. Read the telemetry FIRST. It is free and it is text.**

DJI writes a `.SRT` sidecar per clip at 50 Hz: iso, shutter, fnum, ev, color_md,
focal_len, lat/lon, rel_alt, abs_alt. GoPro writes a `gpmd` stream inside the
MP4 — SHUT/ISOE at the frame rate, ACCL/GYRO at ~200 Hz.

The **180° rule** is the highest-yield criterion: correct shutter ≈ 1/(2 × fps).
At 48 fps that is 1/96. A clip shot at 1/10000 is 104× the convention and its
motion will strobe. **State it as measurement, never as judgment** — a fast
shutter is a choice.

Altitude, ISO and shutter together tell you what a clip IS before you decode a
frame: `rel_alt` flat at 0.0 with ISO 430 is a grounded low-light test, not a
flight.

**2. LOOK before condemning.** Every time. A clip the detector scores at zero can
be a good photograph, and a clip full of candidates can be a deck test.

**3. Then cut, then dispose.**

## HLG footage will lie to you if rendered naively

Drone and modern phone video is 10-bit **HLG BT.2020** (`arib-std-b67`). A
straight frame grab looks washed out and you will misjudge it.

**This machine's ffmpeg has NO HLG path** — no `zscale`, no `libplacebo`, and
`colorspace` rejects `arib-std-b67`. Do not hand-roll the transform. phot-o-MATIC carries
`hlg.sdr.transform` and `hlg.systemGamma` as measured capabilities and its scan
writes correctly-rendered display PNGs. Use the instrument.

System gamma for SDR at 100 nits is **0.78**, not 1.2 — 1.2 is the 1000-nit value.

## phot-o-MATIC, and what its verdict does and does not mean

Use the **CLI**, not the MCP tool, for repeated work. The MCP response embeds the
entire criteria file — roughly 5,000 tokens of identical boilerplate per call
(task #765). `walk scan <file> --json` plus extracting the two fields you need
costs about 50.

**The detector is a whole-frame luminance rise.** On non-storm footage a
"candidate" is a brightness change and nothing more. `boundBy: floor` means the
clip's own statistics wanted a lower threshold than the 1% constant — that is a
clip where nothing happens.

**The shipped criteria are LIGHTNING criteria.** Pointed at a landscape they fire
`nothing-the-classifier-recognizes` and return NOT WORTH THE TROUBLE — a true
sentence that tells you nothing. Measured: a genuinely good ridgeline-and-cloud
frame was condemned this way. **Say so rather than relaying the band.**

## Stills: the acceptance envelope, measured on approved work

From eight frames a commercial reviewer approved and is actively selling:

- **blown highlights 0.00%–0.37%** — eight for eight under 0.4%
- crushed blacks 0.23%–2.90% — an order of magnitude, and all passed

**Highlights are the disqualifier; blacks are not.** Deep shadow reads as intent;
a blown sky reads as an error and cannot be recovered.

Measure the PROPORTION, never the maximum. `YMAX 255` on a photograph is normal
and means the image uses its range. And check what the clipped region IS — 2.79%
"crushed blacks" turned out to be a black car.

## Disposal — and the failure that makes this section exist

Standing practice: **move to Trash, never delete.** Trash via Finder/osascript;
`mv` into `.Trashes` is blocked.

**A single Finder `delete {list of 23 items}` reported rc=0, removed the files,
and they never arrived in the Trash.** Measured 2026-09-13: Finder's own trash
count read 0 immediately afterward, and each file was absent from the exact
`.Trashes/<uid>/` path where a single-file delete lands correctly. 7.6 GB was
unrecoverable, including 195 seconds of footage nobody had reviewed.

**So: delete ONE FILE PER CALL, and verify each landed** before reporting
anything as recoverable. `.Trashes` is mode `d-wx--x--t` — no read bit — so
`find` and `ls` return nothing whether the file is there or not. Test the known
path directly (`[ -f "/Volumes/X/.Trashes/$(id -u)/name" ]`), or ask Finder for
its trash count. **Absence of a listing is not evidence of deletion, and rc=0 is
not evidence of trashing.**

Never scan a volume another process is reading. Check for a running test suite or
scan first — a concurrent cull broke a deploy gate on 2026-09-13 by emptying a
folder the tests asserted on.

## Cutting

Stream-copy (`-c copy`) whenever the pixels should survive — verify with matching
frame hashes, which proves it byte-for-byte. **phot-o-MATIC cannot do this**: its
passthrough path is open defect #721 and it re-encodes, and it never reads, writes
or retimes **audio**, so its segments come out silent.

Any pixel edit to a JPEG costs a generation. Match the original's chroma —
checking `pix_fmt` first — or a 4:4:4 original re-encoded at 4:2:0 loses 3.5 dB
for nothing.
