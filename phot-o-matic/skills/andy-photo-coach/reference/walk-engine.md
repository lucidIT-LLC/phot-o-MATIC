# Andy — the Walk engine

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Contents

- 8.5 The Walk Engine — check its version before you trust this file
  - THIS SECTION IS WRITTEN AGAINST WALK 0.10.2
  - What Walk does at 0.10.0 — MEASURED from `walk_contract` on this host, 2026-09-28
  - What Walk does NOT do at 0.10.0 — do not infer capability from silence
  - Using it
  - Where Walk ends and you begin — decision #496

## 8.5 The Walk Engine — check its version before you trust this file

**Walk is o-MATIC's own rendering and measurement engine** (source home
`lucidIT-LLC/phot-o-MATIC`: `Sources/WalkKit`, `Sources/walk-mcp`; Swift /
Core Image / Vision / AVFoundation). Andy depends on Walk; Walk knows nothing
about Andy. It is **not a skill and must never become one** — it is compiled
code whose numbers can be tested, which is the entire reason it is trustworthy.
Decision #488 ruled the factory would own its engine; #490 measured it; #495
measured the video half; #496 set the Walk-then-coach flow.

**Walk ships inside the phot-o-MATIC plugin** (MCP server name `walk` in
`phot-o-matic/.mcp.json` / host plugin manifests; decision #534's MCP surface,
now distributed with this product rather than as a separate pack) and exposes
an **MCP stdio surface** — `walk_scan`, `walk_scan_folder`, `walk_proof_sheet`,
`walk_segments`, `walk_grade`, `walk_contract`. On a host with phot-o-MATIC
installed you call the tools; the `walk` CLI is the same engine reached the
other way. Tool names stay `walk_*` on purpose (stable API; Walk was the
development name). **No criteria set ships inside the plugin** — Walk's own
contract says so (`coach.verdict` is in `notImplemented` for exactly that
reason). The set that renders a coaching verdict is installed on the host, at
`~/Library/Application Support/Walk/criteria.json` or wherever `WALK_CRITERIA`
names. (2.6.0 said it shipped inside the plugin; the contract has never said
that.)

### THIS SECTION IS WRITTEN AGAINST WALK 0.10.2

(0.10.2 is the same engine as 0.10.0: no engine source changed between them, only the plugin's packaging; phot-o-MATIC CHANGELOG 0.10.2. The measurements below were taken on 0.10.0 and hold for 0.10.2.)

**Run the check before relying on anything below.** Call `walk_contract` with
`expect: "0.10.2"`, or on a CLI host:

```
walk contract --expect 0.10.2
```

Equal passes. Exit **1** means this file and the engine disagree, and the check
says which direction:

- **Walk is NEWER than 0.10.2** — this file was written against older behavior.
  Do not proceed on it as written. Read the live `walk_contract` capability
  list and report the mismatch to the operator.
- **Walk is OLDER than 0.10.2** — capability described here does not exist yet.
  Do not claim it.
- **Walk not installed** — the phot-o-MATIC plugin (and its `walk` MCP server)
  is not on this host. That is a host configuration gap, not a degraded
  factory. Say so and fall back to §9.

**A running host can serve an older Walk than the one installed.** The MCP
server is a process started with the session; a plugin update does not replace
it. Measured 2026-09-28: with 0.10.0 installed, a session started before the
update answered `walk_contract` as **0.9.0**, and the check refused it, as it
should. The fix is a host restart, not a re-pin. Re-pin only against the
installed binary.

**Why a version check and not a paragraph saying "keep this current."** This
factory's single most repeated defect is prose describing code that has since
changed, with nothing able to notice: retired KB numbers cited as live
authority, rule #259 naming a connection that had been renamed, and this
skill's own 2.2.0 reversed `magentaGreen` sign passing every verifier while two
sections of this file contradicted each other. In every case a document
described a mechanism that no longer existed. **A document that cannot detect
its own staleness will be served as current indefinitely.** The check exists so
this section can fail loudly instead of lying quietly, and it was proven to fail
in all three directions before shipping — a check that has only ever passed is
not a check.

**AND IT HAS FIRED TWICE, EXACTLY AS DESIGNED — that is why this section reads 0.10.0.**
Shipped at 2.5.0 pinned to `--expect 0.2.0`, this section spent the interval
instructing every session *"Walk is NEWER… do not proceed on it as written"*
about its own contents. Task #729 re-pinned it to 0.5.7 at 2.6.0. Walk then
shipped 0.7.0 through 0.10.0 and the 0.5.7 pin fired again. Task #1013 re-pinned
it to 0.10.0 at 2.7.0. The pin is not decoration; when it fires, re-measure and
re-pin.

### What Walk does at 0.10.0 — MEASURED from `walk_contract` on this host, 2026-09-28

| Capability | Since | What it gives you |
|---|---|---|
| `hlg.sdr.transform` | 0.1.0 | ITU-R BT.2100 inverse HLG OETF → OOTF → BT.2020→709 |
| `hlg.systemGamma` | 0.1.0 | BT.2390 derivation from target display nits |
| `grade.filmic` | 0.1.0 | Hable tone map — holds highlights instead of clipping |
| `measure.mean` / `measure.meanRaw` | 0.1.0 | channel means, colour-managed and unmanaged |
| `measure.castCheck` | 0.1.0 | channel-spread delta across a grade |
| `contract.version` / `contract.reasons` | 0.2.0 / 0.4.0 | this check, and a reason on every absence |
| `video.read` `video.write.reencode` `video.retime` `video.scan` `video.detect` `video.segment` `video.trim` `video.yPlane` | 0.3.0 | the video half #495 measured, now shipped |
| `classify.vision` | 0.3.0 | Vision classification, no model file |
| `colorspace.linear2020` | 0.3.0 | pinned linear BT.2020 — the space every `relativeRise` figure is in |
| `grade.still.api` | 0.4.0 | stills through the same grade path |
| `ingest.folderScan` · `scan.clip` | 0.4.0 | enumerate and scan a folder or one clip |
| `app.proofSheet` · `thumbnail.displayPNG` | 0.3.0 / 0.4.0 | a proof sheet, and PNGs you can actually show |
| `mcp.stdio` | 0.4.0 | the six `walk_*` tools |
| `ingest.stills` · `sheet.manifest` · `sheet.progressive` · `sheet.timeSampled` · `telemetry.djiSRT` | 0.5.5 | stills in the walk, sheet variants, DJI SRT telemetry |
| `coach.bands` · `coach.criteria` · `coach.evidence` | 0.5.0 | the three verdict bands, the versioned criteria loader, the evidence trail |
| `coreml.custom` | 0.5.7 | your own CoreML model |
| `video.write.passthrough` | 0.9.0 | segments copied from the stored bitstream, no re-encode, each read back before it is reported |

0.10.0 adds no capability. It changes what the tools return, and three of those
changes matter to you:

- **A scan carries the criteria's identity, not its reference.** `walk_scan` and
  `walk_scan_folder` return `coach.available` and the criteria identity
  (`version`, `walk`, `owner`, `established`, `source`, `rules`), plus one line
  pointing at `walk_contract`. The band shapes, the lessons and the forward
  question are served by `walk_contract` alone. Show a verdict's `label`, never
  its `band` key.
- **A failed stage carries a reason.** Each candidate carries
  `failures: [{stage, reason}]` for any decode, classify or thumbnail stage that
  failed. `vision: null` no longer stands in for a classifier that crashed.
- **An unreadable folder is not an empty one.** Folder scans and proof sheets
  report `unreadable` with a reason per folder. Read it before you tell the
  operator a folder had nothing in it.

And one from 0.8.0: **per-candidate `sigma` is gone from the wire.** It was the
rise column rescaled by one per-clip constant, so it ranked identically to
`relativeRise` and read as a second, agreeing instrument. `detector.robustSigma`
is still reported per clip.

### What Walk does NOT do at 0.10.0 — do not infer capability from silence

`coach.verdict` · `coach.stills` · `app.drive` · `ingest.dump` ·
`ingest.triage` · `page.bestWorst` · `touchup` · `fcpxml.export` ·
`video.audio`

**Two of those absences are yours and you must not paper over them.**

- **`coach.stills` — WALK CANNOT JUDGE A PHOTOGRAPH.** It measures stills and
  shows them; it cannot band one. Of the seven selectors the coach reads,
  exactly one survives the move to a still: `relativeRise`,
  `relativeRisePercent`, `sigma` and `mergedFrames` are all derived from
  temporal neighbours a photograph does not have, and `yMean`/`yMax` are 10-bit
  Y-plane code values a still never produces. Measured 2026-09-12: a still hand
  built as a Candidate was banded NOT WORTH THE TROUBLE by a rule reading
  `relativeRise atMost 0.01`, because the fabricated zero satisfied it — a
  photograph condemned by a measurement that does not exist for it, with an
  audit trail that looked complete. **Judging the photograph is §s 4, 5 and the
  Scoring Rubric in this file. That is you, not Walk.**
- **`app.drive`** — Walk driving Affinity or any other app. #494 puts actuation
  outside the engine. Driving the app is §9, over the connector.

`coaching.available` is a **host** fact, not a build fact: with a criteria set
installed Walk returns banded verdicts, and `walk_contract` reports which set,
which version and where it was found. Read those fields; do not assume either way.
On this host on 2026-09-28 it read `available: true`, criteria **1.4.0**, 9 rules,
written against Walk 0.10.0. That is a reading of one host on one day, not a
promise about yours.

### Using it

```
walk <in> <out> [neutral|dramatic] [targetNits]
```

It prints a baseline, the result, and a cast check, and **exits non-zero rather
than grade an image whose baseline it could not measure** — the same discipline
§5 requires of you. Read its numbers as your before-and-after; do not re-derive
them.

Two behaviours worth knowing, both from its first run:

- **The system gamma is not 1.2.** 1.2 is the value for a 1000 cd/m² HDR
  display. SDR at 100 cd/m² is 0.78. Gamma above 1 darkens shadows — hardcoding
  1.2 crushed an entire storm foreground to pure black and read as an aggressive
  grade rather than a units error. Pass `targetNits` deliberately.
- **HLG is a capture format.** Footage that looks flat is not badly shot, it is
  untransformed. Saying "flat" about un-transformed HLG is the same error class
  as calling a RAW file dull.

**A third, and it costs frames if you forget it.** Every percentage Walk's
criteria and lessons quote is the **linear** rise `relativeRise` reports, never
the gamma-encoded Y-plane rise. The two are different quantities with no fixed
factor between them — on clip 0012 the same event reads +36.03% linear against
+6.02% on the Y plane. Rank by brightness and you hand back the wrong frame:
that clip's first scan lost two real cloud-to-ground strikes exactly that way
(decision #504, units labelled under task #740).

### Where Walk ends and you begin — decision #496

**Walk triages hands-off; you finish hands-on.** Walk goes through the whole
dump, builds the page of best and worst, and does the fast work. You take the
finals, in the operator's own application, with him. The operator's words:
*"walk then pixel works in your app with you."* — recorded verbatim from before
the rename; the coach he names is you.

So Walk does not replace §9. Affinity is **demoted from instrument to target**:
you no longer need it to measure, because Walk reads the full buffer and closes
the loop itself — but it remains the place the operator's hands are, and driving
it for him is your half of the flow. **REPORTED, not measured:** no spike has
been run on you driving a third-party app under this architecture (#496
rationale). Do not claim that half works until it has been.
***
