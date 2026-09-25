# Changelog

## 0.9.0 — 2026-09-25 — task #721 closes: passthrough ships, and the 22 frames were never lost

**`video.write.passthrough` moves from `notImplemented` to the contract.**
`walk segments --passthrough` and `walk_segments` with `passthrough: true`
copy the stored bitstream — no decode, no encode, no retime — and every file is
read back before it is reported. Frames requested and frames decodable are the
same number or the segment is `WalkVideoError.frameCountMismatch`; a decoder
that refuses the file is `WalkVideoError.readbackFailed`. Neither is a warning.

**WHAT #721 ACTUALLY WAS.** The 2026-09-12 spike (decision #495) appended 122
samples, every append returned true, `writer.status` was `.completed`,
`writer.error` was nil, and the file "held 100 decodable frames" — 22 frames
lost, filed as the write-path instance of absence-indistinguishable-from-success.
Re-measured 2026-09-25 with the identical request (clip 0012, frames
2300..<2400), reader and file probed separately:

- the passthrough reader delivers **120 media samples, frames 2280…2399**, plus
  **4 zero-sample marker buffers** (one at the requested start carrying no data,
  two with no timing at all, one `EmptyMedia`/`PermanentEmptyMedia` at the
  requested end). 2300 is twenty frames into a 30-frame GOP — key frames at
  2280 and 2310, measured with `ffprobe -skip_frame nokey` — and compressed
  video decodes only from a sync sample, so the reader begins at 2280;
- the finished file **held exactly the 100 frames asked for** (ffprobe
  `nb_read_frames=100`, `nb_frames=120` stored, duration 1.668 s; AVAssetReader
  readback 100).

Nothing was lost. A count of samples appended — twenty of them GOP lead-in the
file must carry for the requested frames to decode at all, two of them marker
buffers — was compared to a count of frames presented, and they are not the same
quantity. Cause (3), "passthrough cannot start mid-GOP", is not a defect; it is
what a GOP is. The defect was in the instrument, and the file was right.

**The path as shipped does what Apple's documentation says and nothing
cleverer** (AVAssetWriterInput.h, AVAssetWriter.h, AVAssetReader.h in the
macOS 27.0 SDK; developer.apple.com/documentation/avfoundation, read
2026-09-25):

- samples go to the writer in **decode order as delivered** — `append(_:)`:
  "order and append them according to their decode timestamp". The spike's
  cause (1) treated decode order as a defect and re-based timestamps on the
  first sample, which was a marker;
- `startSession(atSourceTime:)` is the **requested** start — "samples with
  timestamps earlier than startTime will still be added to the output file but
  will be edited out"; `endSession(atSourceTime:)` is the requested end;
- `SampleBufferReceiver.append(_:)` "suspends until the input is ready for more
  media data" — the documented replacement for the `readyForMoreMediaData`
  loop, and the reason the tight-loop `NSInternalInconsistencyException` of
  2026-09-12 cannot recur;
- every append has returned before `finishWriting()` — "to guarantee that all
  sample buffers are successfully written, ensure all calls to append have
  returned before invoking this method";
- `mediaTimeScale` and `movieTimeScale` are the **source's** (60000), not
  QuickTime's default 600. MEASURED without them: `time_base=1/600`, every
  1001/60000 s frame quantized to 10 ticks with a periodic 11 to catch up,
  `avg_frame_rate=72000/1201`, AVFoundation reading 59.88 fps against 59.94.
  The count verified and the clock had been rewritten. With them:
  `time_base=1/60000`, `r_frame_rate=avg_frame_rate=60000/1001`.

**Acceptance, as the task stated it, measured:**

- clip 0012, 2300..<2400 (mid-GOP start): 100 requested, 100 decodable, 20
  lead-in samples, 4 markers; source frame 2347 lands at output frame 47 with
  a 10-bit Y mean of **439.098 — bit-exact**, against 439.079 through the
  re-encode path;
- clip 0011, 1234..<1361 (both ends mid-GOP): 127 requested, 127 decodable,
  4 lead-in;
- clip 0012, 2280..<2400 (key-frame aligned): 120 requested, 120 decodable,
  0 lead-in;
- the CLI on clip 0012 `--frames 2300-2400 --passthrough`: one 175-frame
  segment, 199 samples stored, 24 lead-in, `nb_read_frames=175`, 54.3 MB,
  **5,197 samples/s copied** against 86.6 fps for the re-encode on the same
  machine;
- **the control can fail:** `anInducedLossSurfacesAsAnErrorNotAShortFile` drops
  one media sample from inside the requested range before it reaches the
  writer. The writer reports success. The readback throws — measured as
  AVFoundation −11821 "Cannot Decode", surfaced as `readbackFailed` with the
  count decoded before the refusal. A file that reports success and holds less
  than asked cannot leave `passthrough(_:frames:to:)`.

**Eight tests added** in `Tests/WalkKitTests/PassthroughTests.swift`: five on
the storm fixtures (skipped where the archive is absent, reported as skipped),
three that run everywhere (the report cannot call a mismatch verified, the
comparison is requested-vs-decodable and never appended-vs-decodable, the error
names its numbers, the contract carries the capability). Contract version
anchors re-aimed for 0.9.0.

**Unchanged:** the re-encode path, its retime, its readback control, and every
other capability. The `walk_segments` schema gains one optional boolean;
existing calls behave exactly as before. Segments still carry no audio.

## 0.8.0 — 2026-09-25 — task #740 closes: the per-candidate `sigma` column is gone

**THE WIRE CHANGED, DELIBERATELY, AND THIS IS THE NOTICE.** Per-candidate
`sigma` is no longer emitted — not on the `walk scan` text sheet, not in
`--json` events, not in the `walk_scan` / `walk_scan_folder` candidate object,
not in the app's detail pane. Every other candidate field is unchanged.
`detector.robustSigma` stays. The `sigmaDerivation` string that 0.5.0 added is
replaced by `detector.sigmaNotEmitted` (and the `--json` top-level key of the
same name), which states the removal and the recipe.

**WHY REMOVAL AND NOT RE-DERIVATION.** Task #740's acceptance was binary:
"derive sigma from the clip's actual robust dispersion or stop printing it."
0.5.0 did a third thing — kept the column under a four-line disclaimer — and
Data's 2026-09-14 review correctly held that an acceptance criterion quietly
satisfied by a different remedy is the task's own defect class. The operator
directed the fix on 2026-09-25. The first remedy is not available:
`robustSigma` already *is* the clip's actual robust dispersion, 1.4826 × MAD of
the relative-rise series, and any per-candidate z-score is rise divided by that
one per-clip constant — the rise column rescaled, by construction, whatever
estimator produces the constant. **Reproduced on clip 0012 before the change:
13 of 13 candidates at `sigma / rise%` = 39.87533**, varying only in the seventh
figure. Two columns that rank identically are one instrument printed twice, and
a reader — human or model — took them as two agreeing. So the column goes and
the one honest figure, the clip's dispersion, stays where it always was.

**Criteria files are NOT broken.** `sigma` remains a rule selector in
`Criteria.swift` and `ClipScan.Candidate` still carries the value internally,
so a 0.5.x criteria set with a rule on `sigma` still loads and still fires
(it was always a rule on rise). The README says so beside the selector list.
The installed criteria set on the build host uses `relativeRisePercent`,
`vision.*` and `yMax`; none reads `sigma`.

**New gate: `make sheet-check`** (`.github/check-sheet-shape.sh`), in `verify`
and CI. It asserts the field is absent from every emitter and that the
`sigmaNotEmitted` notice is present, and proves both directions can fail under
`--selftest` against planted fixtures. The engine-side identity test,
`sigmaIsRelativeRiseRescaledByOneConstantPerClip`, is kept and its docstring
now records that the removal rests on it.

**The other three defects on #740 were closed earlier and are unchanged here:**
units on `rise` named in every surface (0.5.0, aa22851 / 609441f / e12314e);
`inlineImages.frames` states its order and the written PNGs were never
mis-ordered; classifier confidence is a rank and never a gate. The owed
`luminanceIsNotLightning` figures were re-measured off the engine in 609441f.

`walk_contract` reports the same capability set as 0.7.0; nothing was added or
removed from `Walk.capabilities` or `notImplemented`.

## 0.7.0 — 2026-09-14 — the product is **phot-o-MATIC**, and the pack moves out of the root

**WALK WAS THE DEVELOPMENT NAME.** The product, the public mark and the
repository are `phot-o-MATIC`, lowercase p, with the house `o-MATIC` suffix
intact. **Every entry below this one is preserved exactly as written, under the
old name, deliberately.** They record what happened on the dates they happened,
when the product *was* called Walk; rewriting them would assert the product
carried a name on a date it did not, in the one file whose whole job is to be
the true record. Retirement is a state, never an erasure.

**THE WIRE DID NOT MOVE, AND THAT IS THE POINT.** The six MCP tool names
(`walk_scan`, `walk_scan_folder`, `walk_proof_sheet`, `walk_segments`,
`walk_grade`, `walk_contract`), the `WalkKit` module, the `walk` and `walk-mcp`
binaries, the criteria file's `walk` engine-version field, the `"walk"` JSON
response key, `serverInfo.name`, the `Walk` enum, the `WALK_*` environment
variables, the `sellableAsShot` band key and the on-disk
`~/Library/Application Support/Walk/` criteria directory are all unchanged. They
are the stable API and an installed criteria set must not go dark because a
product was named. A tool rename is a breaking schema change and gets its own
deliberate pass.

**THE QUALIFIED TOOL NAMES DO CHANGE, even though the tool names do not.** A
host composes `mcp__plugin_<plugin>_<server>__<tool>`, and the plugin name is
half of that. `mcp__plugin_walk_walk__walk_scan` becomes
`mcp__plugin_phot-o-matic_walk__walk_scan`. **Any saved permission rule or
allowlist naming the old qualified form silently stops matching** — it does not
error, it simply no longer applies. Re-approve the tools once on first use.

**THE REPOSITORY IS THE MARKETPLACE; THE PACK IS `./phot-o-matic`.** It used to
declare a plugin `source` of `"./"`, which Claude Code rejects — a repository
cannot be both the marketplace and the plugin at its root. **That is why the
plugin could not be installed**, and it was independent of the rename. The
marketplace manifests now sit at the root (`.claude-plugin/marketplace.json`
and, for Codex, `.agents/plugins/marketplace.json`) and the pack sits one
directory down, the same shape as every other o-MATIC door. `make plugin-check`
now asserts it, and the assertion was demonstrated failing against `"./"` before
it was trusted.

Install line: `claude plugin install phot-o-matic@phot-o-matic`.

**New gate: `make name-check`.** A retired-product-name detector scoped to the
published surface, with an allowlist that carries a written reason per token —
and, under it, an **inverted** assertion that fails when a *held* wire token
stops appearing. The second half is the one that matters: a one-directional
check only punishes under-renaming, and the defect this estate has actually paid
for is the other direction, a substitution pass eating an API identifier that
looked like a name. Both directions are proven on planted fixtures under
`--selftest`.

**THE LICENCE FILE CHANGED, AND NOT TO A DIFFERENT LICENCE.** `LICENSE` used to
contain the MIT Licence while every shipped manifest declared `BUSL-1.1`. Both
were wrong and only one was dangerous: published, MIT would have been an
irrevocable grant to anyone to copy, modify and resell this. The MIT text is
gone and **no licence is granted** — the file now says so in terms. The
manifests still declare `BUSL-1.1`, which is *not* a settled choice and is
recorded as such; the contradiction is left visible rather than resolved by
picking one, because choosing a licence is not a build decision. **You have no
right to use, copy, modify or distribute this.**

**WHY THE VERSION IS 0.7.0 AND NOT A PATCH.** The plugin was renamed, its layout
moved, and its licence file changed. None of that is a bug fix, and a host that
saw `0.5.7` before today would have no way to tell that anything happened. 0.5.6
and 0.5.7 were never tagged; this release is.

Not yet published. The public repository does not exist and creating it is a
separate, gated step.

## Unreleased — Pixel is gone (decision #538), and the gate stops existing twice

**THE CONFORMANCE CHECK EXISTED IN TWO PLACES AND HAD ALREADY DIVERGED.** This
is the headline defect and neither Carver nor Smith had named it. MEASURED
2026-09-13, by running both copies:

| | `Tools/brand-gate/` (Walk) | `artifacts/walk/brand-gate-eval/` (O-Matic) |
|---|---|---|
| #536 re-aim of N2 / N8 | yes | **no — pre-ruling detectors** |
| green baseline fixed | yes | **no — still reports FAIL on its own clean case** |
| N2 fixture re-aimed | yes | **no — reference only in `origin`** |
| path under test | `walk-criteria.json` | **`pixel-criteria.json`, renamed out of existence by #775** |

The stale copy raised `FileNotFoundError`, printed a traceback, **and exited 0**.
A control that crashes and reports success, sitting inside the check built to
catch exactly that.

**ONE HOME, ENFORCED MECHANICALLY.** The Walk repository is the home: the gate
runs in Walk CI, the artifact under test lives here, and a plugin consumer can
run it. The O-Matic path now holds a stub that **refuses with exit 2** rather
than an empty directory (which invites re-creation) or a README (which nobody
executes). `Tools/brand-gate/check-single-home.sh` enforces it and is **proven
able to fail in 7 cases**, including the subtle one — the stub replaced by
something that exits 0, which is how a second copy returns without adding a
file. It runs as PART 0 of the suite, before anything else, because proving nine
detectors load-bearing in a copy nobody runs proves nothing.

Where the estate path does not exist (a CI runner) the check says **"not
evaluated"** rather than "ok". A check that is vacuous where it runs must not
report the same word as a check that passed.

**THE N7 FIXTURE IS RENAMED AND ITS ASSERTION IS UNCHANGED.**
`N7-pixel-criteria.json` → `N7-monet-criteria.json`. N7 reads
`os.path.basename()`, so a fixture renamed to carry no roster name at all would
have stopped reproducing its own defect — the same trap that had already
disarmed the N2 fixture. Using a different roster name is also a stronger test:
it proves N7 catches roster names generally, not one hard-coded string.

**`cp` OVER A MACH-O IN PLACE GETS IT SIGKILLED, and this had been latent in
every staging path.** Found while restaging after the rename. MEASURED, isolated
in three runs: `cp` over the existing binary with CHANGED content → `--version`
exits 137; `rm -f` then `cp` → exits 0; `cp` again with now-identical content →
exits 0. The kernel caches a signature validation against the vnode, and new
bytes in the same inode leave that cache describing a binary that is no longer
there. It fires on every real re-stage after a source edit and never on the
re-run someone does to reproduce it. THE FAILURE WORE THE WRONG NAME: the check
reported "does not report a version", which reads as a broken build — the build
product printed its version correctly throughout. Fixed in
`.github/stage-binary.sh`, so all three front doors get it at once.

**THE ONE QUOTED PRONOUN, PARAPHRASED RATHER THAN EDITED.** A served
`walk_contract` string carried decision #499's clause in quotation marks, and
after the rename it read *"Andy's hard-earned logic ... because \"a Walk not
carrying **her** experience is a light meter.\""* Operator ruling: paraphrase it
out of quotation marks. #499's verbatim text stays exact where it is
authoritative — in `factory.decisions`, untouched, pronoun and all, because that
record is his words on the date he said them. What ships to a customer is not
the quotation, it is the doctrine. It now reads:

> #499 rules that Andy's hard-earned logic is what renders it — a Walk that does
> not carry it is a light meter.

No `[sic]`, no `[his]`: a customer-facing string is the wrong place for an
editorial apparatus. SWEPT for others rather than fixing only the one found —
three more hits, all in source comments rather than served strings, and the two
verbatim #499 fragments among them were LEFT in their quotation marks, a doc
comment being the right place for a quotation. Measured over the wire after
rebuild: the served contract contains no "her" and no "Pixel".

**THE STALE-CONSUMER GATE COULD NO LONGER FAIL, AND HAS BEEN RE-AIMED.** It read
`--expect 0.2.0` and was named for "Pixel 2.5.0 §8.5". MEASURED off the live host
surface: the consumer is now `andy-photo-coach` 2.6.0 in studio pack 1.10.1,
`pixel-photo-coach` is absent, and its §8.5 pin has been corrected to 0.5.7 — so
the gate named a consumer that no longer exists AND watched a defect already
closed. Replaced by the permanent half of it, in two steps:

- **the OLDER-consumer refusal**, with the version DERIVED from `Walk.version`
  rather than written down, so it cannot go stale the way the literal did. The
  newer and unparseable directions already had their own steps; older did not.
- **the real consumer's pin, read out of the installed skill rather than out of
  a comment**, required to be ACCEPTED. This is the part that catches the next
  drift. Absent on a CI runner, where it says "not evaluated" rather than
  passing silently — absence is not agreement.

Both PROVEN able to fail: `--expect 0.0.1` refused while `--expect 0.5.7` is
accepted, and a fixture skill pinned to 0.2.0 drives the second step red.

**PIXEL → ANDY ACROSS THE REPOSITORY (decision #538).** The operator's rule was
the test for every hit: *"the only part of pixel that survives is the logic we
had in it."* The logic survives untouched — the nine rules and their ordering,
the thresholds, `luminanceIsNotLightning` and its measured numbers, and the
recorded retraction of `residual-glow-after-the-strike`. The name does not,
where it is authorship or voice. 26 attributions changed, including every string
served through `walk_contract` and the `walk-mcp` instructions a host reads
before it picks a tool.

ONE DISTINCTION DECIDED EVERY HIT, and it is mechanical: `Pixel N.N.N` and
`Pixel §X` are CITATIONS to a specific versioned document, and renaming one
makes it point at nothing, so they are LEFT. Bare `Pixel` / `Pixel's` is
authorship, and becomes Andy. Per #421, retirement is a state rather than a
delete: changelog history and commit messages describing what shipped under the
old name stay exactly as they are.


## Unreleased — Walk becomes the plugin (decision #534, phase 1)

**THE REPOSITORY ROOT IS NOW THE PLUGIN ROOT.** `.mcp.json`,
`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
`.codex-plugin/plugin.json`, `skills/` and a prebuilt `bin/walk-mcp` are the
payload a host clones. MEASURED end to end on this machine: `claude plugin
marketplace add` accepted the repo, `claude plugin install walk@o-matic-walk`
succeeded, and the host loaded the server and all three skills — 6 tools,
`walk-mcp 0.5.7`, arm64 Mach-O, no `com.apple.quarantine`. Payload size 1.4 MB.

**PHASE 1 SHIPS THE ENGINE AND NO JUDGMENT.** No criteria set is in the payload,
so `Coaching.shippedCriteriaJSON` stays nil and the contract is unchanged.
`coaching.available` remains HOST state and is reported as such.

**`${CLAUDE_PLUGIN_ROOT}`, NOT `${PLUGIN_ROOT}`.** MEASURED against the vendor's
own plugins reference, which states it in terms: *"Exact variable names:
CLAUDE_PLUGIN_ROOT (not PLUGIN_ROOT)."* The undocumented spelling does not
expand, so a host spawns `/bin/sh` on a path starting with a literal dollar sign
and the plugin reports no tools — which reads as "not configured yet" rather
than as a bug. `make plugin-check` fails on the wrong spelling, in both
directions.

**THE LAUNCHER IS A SCRIPT, NOT A BARE BINARY NAME** (task #735). A GUI-launched
host inherits the minimal system PATH, so a bare name is unresolvable. The
launcher resolves the plugin root from `$0` rather than trusting the
environment, enforces the declared macOS 26 / arm64 floor, and refuses a
quarantined binary by name instead of leaving it to dyld.

**A HOST THAT CANNOT RUN WALK GETS A SENTENCE, NOT SILENCE.**
`bin/omatic-walk-degraded-server.sh` is a real MCP server that advertises zero
tools and puts the reason in `instructions`. A spawn that simply dies is
indistinguishable from a plugin nobody has configured — this factory's most
repeated defect class, arriving where it costs a support ticket.

**`make stage-plugin` CALLS `.github/stage-binary.sh` AND DOES NOT REIMPLEMENT
ITS CHECK.** The plugin binary is a third front door, and #729 is precisely what
happens when a front door has no shared version check. Same script, different
bindir; `--selftest` still proves all five cases.

**THE #254 BRAND GATE IS IN CI AND IT IS RED ON A REAL VIOLATION** (task #772).
Smith's conformance check moved to `Tools/brand-gate/`, and his own closing
caveat is what this closes: the gate stayed design_verified "until it lands in
CI and something red actually blocks a release."

Two detectors were RE-AIMED under operator ruling #536, which changed what
counts as a violation. N2 no longer flags an internal reference in `origin` —
#536: *"the audit trail IS the decision number"* — but still flags one in the
owner string and in free prose. N8 is inverted: an origin's ANCHOR is now what
satisfies #499 field 4, and its absence is the defect, with three accepted
anchors (a ruling, a measurement, or an explicit disclosure that judgment set
the threshold) because requiring only one of them would force three rules to
invent provenance they do not have.

Two defects were MEASURED in the suite itself and fixed: the green baseline
fixture was not green (it trips N6 three times, so the suite had reported RED on
a clean tree since it was written), and the N2 fixture planted its reference
only in `origin`, so the re-aim would have left that detector silently untested.

Findings against the shipped criteria set: **53 before, 12 after the re-aim, 0
unwaived after the operator's ruling.** Only the three N6 lines remain waived,
under Brandy's standing Class 4 verdict, and they stay visible in every run.

**THE #505 / #536 RECONCILIATION WAS ROUTED, NOT GUESSED, AND THEN RULED.** Nine
findings — six `Pixel`, three `skill 2.5.0`, all in `origin` — sat RED for one
pass because #536 and #505 pointed opposite ways and the reading that resolved
them was also the one that turned the build green. Operator ruling, 2026-09-13:
the persona name and the pack version come out; every decision number stays.
#536 overruled Brandy on ONE thing — that internal decision IDs are unacceptable
public provenance — and its text argues about decision numbers and nothing else;
Brandy's #254 Class 2 block on persona names was never overruled; Smith had
already named the remedy as *"rename Pixel→Andy, not delete"*, because stripping
the name collapses five rules.

APPLIED UNDER A GUARD rather than by inspection: all 13 internal references
across the nine origins were extracted before and after, in order, and nothing
was written until they compared identical. 6 of 9 origins changed, 0 references
moved. `Pixel` and `skill 2.5.0` now appear zero times in the file.

The N8 three-anchor logic is confirmed rule by rule after the edit, and it earns
its keep: `bolt-core-on-the-ceiling` is anchored ONLY by its judgment
disclosure, which is precisely the rule a single-anchor gate would have forced
to invent a measurement.

The CI gate's `continue-on-error` came off in the same commit that made it
unnecessary. A softening that outlives its reason is the defect this repository
is built around.

**`criteria/pixel-criteria.json` IS NOW `criteria/walk-criteria.json`** (task
#775). A retired persona name in a filename bound for a public marketplace repo
is customer-facing copy. MEASURED: the old name had ZERO references anywhere in
Sources, Tests, the Makefile, CI or the README, so nothing broke. The documented
host override path, `~/Library/Application Support/Walk/criteria.json`, is
untouched and still resolves.

**`criteria.owner` NOW NAMES ANDY AND THE 903-WORD `criteria.note` IS OUT OF THE
SHIPPED ARTIFACT** (task #770). The note was preserved FIRST, which was Smith's
binding sequencing control: its text and a migration that lands it in a factory
row are written and verified byte-identical before the removal ran. The nine
`origin` fields are BYTE-IDENTICAL — ruling #536 cancelled that rewrite, and a
test asserts they did not change.


## 0.5.7 — the custom Core ML path, because code and tests now stand behind it

**0.5.6 IS SKIPPED.** The operator does not use six in a version number. Noted
so the gap is not read as a lost release.

**`coreml.custom` MOVED, AND WHAT CHANGED IS NOT THE MEASUREMENT.** The 0.5.5
reason already recorded that `MLModel.compileModel(at:)` is a runtime API in
CoreML.framework, that it compiled a custom `.mlmodel` in 16 ms, and that the
result loaded through `MLModel(contentsOf:)` and `VNCoreMLModel` from a plain
SwiftPM binary with no Xcode project and no app bundle. That was true then and
it is true now. The reason also said, in terms, why the capability was staying
put anyway: *"declaring a capability off the back of a spike, with no code and
no test behind it, is the drift this contract exists to catch."* `CustomModel`
and `CustomModelTests` are the code and the tests. The gate was satisfied, not
lowered.

**IT SHIPS NO MODEL AND NAMES NO SUBJECTS.** Decision #507 records that nobody
has scoped what Walk should classify on non-storm material, and that scoping is
the operator's and Andy's. `CustomModel` loads a model the caller supplies and
takes no position on what is in it. `classify.vision` — Vision's built-in
1303-identifier taxonomy, no model file — is unchanged and still covers the
storm case.

**THE FIXTURE IS A KNOWN ANSWER, NOT A TAXONOMY.** 16 KB, two classes (`red`,
`blue`), CreateML-trained on flat colour tiles, regenerable with
`Tools/make-known-answer-model.swift`. It is small because it references the OS
feature extractor rather than embedding one, so unlike `KnownAnswerTests` — which
needs 780 MB on an external volume and skips without it — this suite runs
anywhere. Three of its six tests assert REFUSALS: a missing file, a wrong
extension, and 4 KB of `0x41` named `.mlmodel`. A load path that has only ever
succeeded is not evidence that it validates anything.

**ONE PACKAGING TRAP, MEASURED, BECAUSE IT WOULD HAVE MADE THE TEST VACUOUS.**
Declaring the fixture with `resources: [.process("Fixtures")]` makes the build
system recognise a Core ML model and compile it, so what lands in the bundle is
`WalkKnownAnswer.mlmodelc` and the `.mlmodel` is gone. The test would then prove
the BUILD can compile a model, which was never in question, instead of that WALK
can compile one at runtime, which is the claim. `.copy` carries the bytes
through untouched.

**`fcpxml.export` DID NOT MOVE, AND ITS REASON GOT NARROWER.** No WalkKit code
emits FCPXML; segments still come out as `.mov` only. What changed is the
evidence under the absence. Final Cut Pro 12.3 ships its own DTDs
(`Interchange.framework/.../FCPXMLv1_0.dtd` through `v1_14.dtd`) — a better
authority than the published reference page, which is JS-rendered and returns a
title and no body to a fetch. A five-clip timeline over the operator's own 59.94
GoPro selects was generated from AVFoundation-measured durations and validated
clean against the shipped `FCPXMLv1_13.dtd`, with a negative control proving the
validator can fail. So the format is understood and the writer is still unbuilt,
which is a much narrower statement than "untouched."

**TWO TESTS WERE REPLACED, NOT DELETED, AND THEY FAILED FIRST.**
`theCoreMLReasonNoLongerClaimsTheQuestionIsOpen` and
`coreMLStaysAbsentBecauseNoCodePathLoadsAModel` both failed the moment the
capability moved — which is them working. Their successors assert the new state
and keep the three-step history, because the sequence (false premise → corrected
reason, capability deliberately held back → capability moved once code existed)
is the lesson.

**BAND 1 IS NOW `KEEPER`. DECISION #527, RECORDED AND NEVER IMPLEMENTED.** The
operator retired the label SELLABLE AS SHOT; shipping 0.5.7 without this would
have shipped a name he had already struck. It is a DISPLAY string and the change
is exactly that wide: `Coaching.Band.label` returns `"KEEPER"`, and the enum case
is still `sellableAsShot`. The key rename needs a schema change the operator
deliberately deferred, and propagating half of one is defect #525 — so every rule
in the criteria file still carries `"band": "sellableAsShot"`, and the JSON
surfaces already emit the two separately (`band` is the wire key, `label` is the
display string), which is why the deferral costs a consumer nothing.

**THE BRIEF NAMED FOUR SITES AND A GREP FOUND TEN.** `Coaching.swift` (the
mapping), `Server.swift` (the MCP instructions every consumer reads on connect),
`Version.swift` (the `coach.verdict` reason) and the criteria `note` were the
four. `CoachingTests.swift:84` asserts the literal string and is the gate — it
failed on the old value, which is it working. The two the brief did not name are
`README.md`: the band table, and a transcript of `walk contract` output that
would have started lying the moment the binary changed. Three more are in this
file, in the 0.5.0 section, and they are LEFT ALONE ON PURPOSE — 0.5.0 did ship
SELLABLE AS SHOT, and editing a changelog to say otherwise is falsifying the
record rather than correcting it.

`check-doctrine.py` derives the band labels from `Coaching.Band.label` rather
than keeping its own copy, so it demanded the served prose follow and its
selftest now names band 1 as `'KEEPER'` with all ten cases still caught.

**THE CONTRACT CONTRADICTED THE HOST, AND THE HOST WAS RIGHT.** `coach.verdict`'s
reason ended with *"Every scan therefore reports coaching.available = false with
this reason"* — flatly, of every scan — two sentences before telling the operator
to install a criteria set and promising the verdicts would render from it. Both
could not be true, and on this host `walk contract` was printing
`coach.available: true` with 9 rules loaded while the same command printed that
sentence further up. Data reported it.

The fix is a distinction, not a deletion: **`coaching.available` is HOST state**
and is false only while no matching criteria set is installed; **the
`notImplemented` entry is BUILD state** and stays until a set ships inside Walk.
`Coaching.shippedCriteriaJSON` is still `nil` and still tied to that entry by a
test in both directions, so the entry is correct where it stands — it was the
prose around it that overreached. A consumer reading the contract was being told
its coaching was dark at the moment it was lit.

**THE CRITERIA SET WAS RE-VERIFIED AGAINST 0.5.7, NOT BUMPED PAST A RED LIGHT.**
Walk refuses criteria whose declared engine does not match the running one, so
Pixel's set — written against 0.5.0 — went dark the moment the build said 0.5.7.
`make verify`'s own contract step printed the refusal, verbatim: *"the criteria
file ... was written against Walk 0.5.0 and this build is 0.5.7 ... re-verify the
set and bump its `walk` field deliberately."* The honest way to satisfy that
refusal is to earn it, and the header is now `1.2.0` / `0.5.7` with the
re-verification recorded in the file's own `note`.

What was checked. The nine rules read four selectors — `vision.lightning`,
`vision.thunderstorm`, `relativeRisePercent`, `yMax` — with two comparisons,
`atLeast` and `atMost`. Every file that PRODUCES those numbers is byte-identical
to the 0.5.0 tag: `EventDetector.swift`, `FrameScanner.swift`, `ClipScan.swift`
and `Classifier.swift` return no diff against `e1db0b2`. `Criteria.swift` does
differ and the whole of that diff is the `defaultLocation` test seam in
`resolve` — `Measurement`, `Comparison.holds`, `value(of:on:)` and
`Coach.firstMatch` are untouched. `VideoReader.swift` also differs, and that one
mattered enough to check by hand: the change is `StallWatchdog` bookkeeping
around the decode loop, `armIfRequested()` is a no-op unless
`WALK_TEST_WATCHDOG_SECONDS` is set, and the `Frame` handed back is byte-for-byte
the same object built the same way.

**AND IT WAS CHECKED BEHAVIOURALLY, BECAUSE A DIFF IS AN ARGUMENT AND NOT A
MEASUREMENT.** The installed 0.5.0 engine and the built 0.5.7 engine were run
over the same clips of the operator's own footage with a rule set proven
byte-identical between the two headers, and every verdict's frame, band and
firing rule compared. The units question was asked explicitly, because task #740
landed between these two versions and #740 was a units defect: every percentage
in the criteria file is still the LINEAR rise `relativeRise` reports, #740
changed the PROSE describing those numbers and never the numbers, and `yMax` is
still a 10-bit code value with a 1023 ceiling — so the 1020 guard in
`bolt-core-on-the-ceiling` still means what it meant.

## 0.5.5 — the sheet that shows a folder, not the frames a detector flagged

**THE GAP, MEASURED. `app.proofSheet` has existed since 0.3.0 and it shows
DETECTED CANDIDATES.** That answers "where did the light change in this clip".
It cannot answer "what is on this card", and the difference is not academic: a
candidate is a whole-frame luminance rise, so a clip whose light never changes
produces no candidates and therefore no picture — two of eight GoPro clips did
exactly that in 0.4.0, honestly, and showed blank. MEASURED 2026-09-12:
answering "what is worth keeping in this folder" meant leaving Walk entirely and
hand-writing ffmpeg tile commands, because a TIME-SAMPLED sheet of a whole clip
did not exist here.

`sheet.timeSampled` is that sheet. Every still is one cell; every clip is a
strip of N frames (12 by default) spaced evenly across its whole duration, so
the operator sees the arc of a clip rather than one arbitrary frame.

**`app.proofSheet` did NOT move, and the restraint is the point.** The window it
names was not changed by this release, so claiming it arrived in 0.5.5 would be
a false provenance in the one surface built to prevent exactly that. The new
behaviour is declared under names narrow enough to be true —
`sheet.timeSampled`, `sheet.progressive`, `sheet.manifest`, `ingest.stills`,
`telemetry.djiSRT` — which is #507's `ingest.dump` / `ingest.folderScan`
resolution applied again. `ingest.dump` and `page.bestWorst` stay absent, and
both reasons now name the sheet that DOES exist, because a one-word denial is
how `ingest.dump` came to be read as a flat refusal of folder handling.
`ProofSheetTests` asserts both halves.

**WALK EMITS DATA, NOT A PAGE.** No HTML, no CSS, no styling anywhere in the
engine. `manifest.json` is the artifact and the viewer is separate — a renderer
compiled in here would be a second place for the measurements to drift from how
they are shown.

**Progressive, and measured rather than asserted.** Three passes, and the order
is the feature: metadata first (the manifest is complete, every cell slot
present, `ready: false`, before a single pixel is decoded), then a placeholder
pass, then the sharp cells. The manifest is rewritten ATOMICALLY after every
item, so a viewer polling it watches the sheet resolve and never reads half a
document. MEASURED on the operator's own card — `/Volumes/NVMeExt1/Content/
Photography/DJI_001`, 8 clips, 2 JPG, 1 DNG, 5.8 GB, 99 cells:

```
t+0.73 s   manifest on disk, 11 items, 99 cells, 0 placeholders, 0 ready
t+4.5  s   99 placeholders
t+11.0 s   99 sharp cells, status "complete"
```

**The placeholder path was chosen by measurement, not by reasoning.** It asks
the decoder for the nearest sync sample (infinite seek tolerance), which costs
0.041 s/frame against 0.079 s for an exact frame. The question that mattered was
how to interpret what comes back, and guessing would have been the
system-gamma-1.2 error again in a new place. Measured against Walk's own exact
decode of the same keyframe (450 of `DJI_20260913024928_0001_D.MP4`,
R52.5 G57.5 B62.0):

| placeholder path | mean | |
|---|---|---|
| untagged + Hable curve | R52.4 G58.1 B63.6 | **reproduces the reference** |
| tagged ITU-R 2100 HLG + Hable | R34.7 G39.1 B43.9 | a second decode of something already decoded |
| tagged HLG, no curve | R60.8 G68.0 B76.8 | the curve never applied |

The generator hands back LINEAR LIGHT in an untagged buffer, the same state a
decoded `CVPixelBuffer` arrives in, so what is still owed is the Hable curve and
nothing else. It is therefore a DIFFERENT FRAME from the sharp cell that replaces
it, and `placeholderContract.provenance` says so rather than leaving it assumed —
#740 is what an undocumented correspondence costs.

**DJI telemetry is read as a DISTRIBUTION, never as frame 1.** The obvious
implementation reads the first subtitle block and reports `iso: 100,
shutter: 1/240`. The aircraft is still settling there — climbing, gimbal
levelling, auto-exposure not converged. MEASURED on
`DJI_20260913024928_0001_D.SRT`, 10,782 samples: the modal shutter is 1/10000
holding 58.1% of the file, across 12 distinct values from 1/800 to 1/10000. Every
field is summarized over the whole file and frame 1's value is carried separately
as `firstSample`, reported and never used, with its distance from the median in
stops.

**The 180-degree shutter comparison is a MEASUREMENT, not a verdict.** Correct
shutter is 1/(2 × fps); at 47.952 fps that is 1/96. The operator's two longest
clips measure a median 1/10000 — **+6.70 stops**, an implied shutter angle of
1.7° against 180, with **not one sample in either file** inside a half-stop of
the convention. That is stated with the rule, the tolerance and the share of
samples inside it, and `isAVerdict: false` next to it, because #499 puts
judgment in the criteria file and a fast shutter is a deliberate choice Walk does
not rule on. `theShutterToleranceCanPassAndCanFail` asserts both directions — a
check that has only ever failed is not a check either.

**IT DISPLAYS AND MEASURES. IT DOES NOT JUDGE.** No band, no rank, no score, no
keep/pitch, no ordering by interest — stated in the manifest itself
(`judgment.rendered: false`), in the tool description, in the CLI output and in
three tests, so a viewer cannot add a verdict Walk did not render and call it
Walk's.

**A COLLISION FOUND BY RUNNING IT, which is the only way it could have been
found.** First real run: `DJI_20260517021954_0016_D.DNG` and
`DJI_20260517021954_0016_D.JPG` are the raw and the JPEG of one shot and share a
stem, so both cells were written to `DJI_20260517021954_0016_D_c00.jpg`. The
second overwrote the first, **both reported `ready: true`**, and the manifest
said 99 cells rendered while 98 files existed. Nothing failed and nothing logged
— absence indistinguishable from success, in the artifact whose entire job is
showing the operator what is really on his card. Cell names now carry the source
extension, with a `used` set as the backstop so the invariant is enforced rather
than argued for, and three tests cover it. Re-run: 99 declared, 99 unique, 99 on
disk.

**THE COACHING VERDICT DOES NOT REACH A PHOTOGRAPH, and the contract now says
so.** `coach.bands`, `coach.criteria` and `coach.evidence` were declared with
nothing stating they cover clips only — so a consumer reading the contract would
reasonably conclude Walk can coach a still. That is absence indistinguishable
from success in the surface built to prevent it, and it is the same defect #513
recorded when `app.proofSheet` was declared with no statement that the sheet
does not judge. `coach.stills` is now in `notImplemented` with the whole reason.

THE GAP IS A MISSING PATH, NOT A MISSING RULE, and criteria for stills cannot be
written until it exists. Verified rather than taken on report: `coach.report`
reads a `ClipScan.Candidate`; `StillGrade` mentions neither `Candidate` nor
`Coach`; the CLI's only other route hand-builds a candidate from video findings.
Of the seven selectors in `Criteria.Measurement`, **exactly one transfers to a
still with its meaning intact.** `relativeRise`, `relativeRisePercent`, `sigma`
and `mergedFrames` are each derived from temporal neighbours — a local median
baseline, a per-clip robust sigma, a count of merged adjacent frames — and a
photograph has none. `yMean` and `yMax` are 10-bit Y-plane CODE VALUES read off a
planar YCbCr buffer a still never produces, so reusing those names would be
#740's units error again. That leaves `vision.<identifier>`.

**MEASURED, and it is why the obvious shortcut is worse than no path at all.** A
still hand-built as a `Candidate` — the only route that exists today — was banded
**NOT WORTH THE TROUBLE** by a rule reading `relativeRise atMost 0.01`, because
the fabricated zero satisfied it. The verdict carried the evidence line
`relativeRise measured 0.0, required atMost 0.0100, held true`: a photograph
condemned by a measurement that does not exist for it, with an audit trail that
looks complete. Kept as a test so the shortcut cannot be taken quietly later.
Note the contrast in the same measurement: `yMean` came back `nil` and its rule
correctly did not fire — the "unmeasured is not zero" mechanism already works;
the four video-only fields are non-optional and so cannot use it.

NOT BUILT, DELIBERATELY. Closing this needs an engine-contract decision that
belongs to the operator and to #513, not to an implementer: `Verdict` identity is
frame/timecode/seconds and `frame` runs through all seven `Malformed` cases;
`ClipScan.Candidate`'s video fields are non-optional so they cannot report
`unmeasured`; and what a still should be judged ON has not been scoped — the same
gap `ingest.triage` already records. `page.bestWorst` stays in `notImplemented`
for the same reason `coreml.custom` did: no code, no tests, no capability entry.

**A test that passed by coincidence, and the seam that ends it.**
`withNoCriteriaTheReportSaysSoAndNamesWhereItLooked` asserts the ABSENCE branch
of `Coach.unavailableReason`. It had never tested that branch in isolation: with
no way to inject the default criteria location, the coach fell through to
whatever was installed on the machine, and the test passed only because the
installed set happened to declare the same version as the build. At 0.5.5 the
installed 0.5.0 set was correctly rejected as STALE, that branch rendered
instead, and the test failed. **The assertion text was never the defect.**

MEASURED, and it is why `WALK_CRITERIA` was no way out: `Criteria.defaultURL`
resolves through `FileManager.urls(for: .applicationSupportDirectory, in:
.userDomainMask)`, which reads the user record from the password database and
NOT the `HOME` environment variable — proven by overriding `HOME` in a subprocess
and watching both runs still resolve to the same real path. And `WALK_CRITERIA`
SELECTS an alternative file; it cannot assert an ABSENCE. So the only way to
reach "no criteria installed" from a test was to move the operator's live file.

`Criteria.resolve` and `Coach.init` now take `defaultLocation`, defaulted to the
installed path so no production caller changes. `Resolution` carries the
location it actually consulted, so the absence message names the path it really
searched rather than reading `defaultURL` back and printing one it never looked
at. Seven tests in `CriteriaSeamTests.swift` pin their own location and assert
ABSENT, PRESENT-BUT-STALE, PRESENT-AND-MATCHING, and PRESENT-BUT-BROKEN as four
distinct answers that must not collapse into one message.

PROVEN ABLE TO FAIL, three mutations. Making the seam inert (`resolve` ignoring
the injected location) failed 6 of 8 tests with 18 issues and reproduced the
original bug exactly. Two tests SURVIVED that mutation, which is itself the
finding: the stale-path test passed because the operator's installed file
happens to be stale in the same way — the same coincidence, one level down. So
it was proven separately, by declaring the fixture at the current version
(3 issues, including the built-in `staleVersion != Walk.version` guard), as was
the matching-path test by declaring a version that does not match (3 issues).
All reverted; no mutation markers remain.

**Task #722 re-measured, and the contract's reason for `coreml.custom` was a
FALSE PREMISE.** It read "whether a custom .mlmodel compiles and loads without
Xcode is open." MEASURED 2026-09-12 on macOS 27.0 (26A428), Swift 6.4:
`MLModel.compileModel(at:)` is a RUNTIME api in `CoreML.framework` — an OS
framework, not an Xcode tool — and it compiled a custom `.mlmodel` in **16 ms**.
The result loaded and predicted through `MLModel(contentsOf:)` (pure red in →
`[1, 0]` out, the fixed weights) and through `VNCoreMLModel` + `VNCoreMLRequest`
(pure green → `[0, 1]`), from a plain `swiftc` binary with no Xcode project, no
app bundle and **no deprecation warnings**. A garbage `.mlmodel` was refused, so
the probe can fail. `coremlc` compiles it too and is not needed.

So nothing puts Xcode in Walk's BUILD path, which is what #722 actually asked
and what #490/#495 constrain. What remains gated is AUTHORING — `coremltools` is
not importable in the system `python3` — and that gates making a model, never
compiling or loading one. **`coreml.custom` stays in `notImplemented`**: no
shipped code path in WalkKit loads a model, and declaring a capability off the
back of a spike, with no code and no test behind it, is the drift this contract
exists to catch. The reason now says all of that, and two tests assert the
retired sentence cannot come back.

**Also:** `Frame.makeDisplayImage(maxWidth:exposure:context:)` takes a shared
`CIContext` — the no-argument version built a Metal device and a context per
call, which is right for one thumbnail and wrong for 99 cells. MEASURED
0.079 s/frame shared against 0.104 s/frame fresh, the same picture either way.
`MediaFinder` wraps `ClipFinder` rather than restating the video extension set,
because a private second copy of it is what #507 cost this repository, and it
names why a `.LRF` or `.SRT` was skipped instead of silently omitting it.
`walk sheet` is the CLI front door, because a capability reachable only through
MCP cannot be run by hand when it misbehaves.

**Known and not fixed here, named rather than left to be discovered:** a clip
cell carries the Hable filmic curve whether or not the clip is HLG, because the
sheet uses `Frame.makeDisplayImage` rather than growing a second display path.
On frame 450 above that renders about 15% darker than a plain managed HLG→sRGB
conversion — the highlight rolloff doing what it is for — and each item's
`toneMap` field names exactly what was applied, so a dark cell is readable as a
transform rather than as the footage. Changing a tested path shared with every
candidate thumbnail is a separate decision with its own known answers to
re-measure.

## Unreleased — task #740: the numbers on the proof sheet now say what they mean

**Four defects in one family: a number printed without the thing that makes it
mean anything.** Nothing about the measurements changed. Every fix is to what
the output SAYS about them.

**`sigma` was one measurement printed twice, presented as two.** MEASURED on all
13 candidates of clip 0012: `sigma` is exactly `relativeRise / robustSigma`, and
`robustSigma` is ONE CONSTANT for the clip (2.50782e-04 here), so the ratio is
39.87533 on every single row. Printed side by side with `rise`, a reader sees a
raw value corroborated by a robust statistic; it is one instrument with a scale
factor, and it ranks the clip identically. The column is kept — it is the only
figure that compares ACROSS clips, which a bare percentage cannot — but the CLI
sheet, the `--json` output, the MCP result (`detector.sigmaDerivation`) and the
app's detail pane now state the derivation, and σ is off the app's cards
entirely, where a thumbnail-scale tile has no room to explain it.
`DetectorTests.sigmaIsRelativeRiseRescaledByOneConstantPerClip` asserts the
identity, so the sentence the sheet prints can fail. Proven able to fail:
squaring the rise in the derivation breaks it in two places.

**`rise` never named its colour space, and that omission manufactured a false
finding about the engine.** A reviewer measured frame 2347 at +6.2% on the native
10-bit gamma-encoded Y plane, read `rise +36.030%`, could not reproduce it under
any baseline, and correctly filed `rise` as not reproducible. Both measurements
were right: `rise` is CIAreaAverage in PINNED LINEAR BT.2020, hers was the
gamma-encoded Y-plane mean, and nothing in the output said so. The space is now
named on the sheet, in the JSON (`scan.relativeRiseMeasuredIn`), in the
`walk_scan` tool description and in the app. **And the line that was there was
itself a wrong number in the same family:** it read "the CIContext default is
ExtendedLinearSRGB and measures 4.2x less of the event". Decision #495's own
figures say the default linear sRGB measures +36.34% against pinned BT.2020's
+36.03% — very slightly MORE, not 4.2x less. The 4.2x is the ratio to an 8-bit
sRGB working space (+8.54%). A real figure attached to the wrong comparison, and
a reader could have used it to convert between two numbers it does not relate.
The linear-to-Y-plane ratio is not constant either — 36.03/6.02 on frame 2347,
3.69/0.79 on frame 2388 — so the output now says no single multiplier converts
them rather than offering one.

**Inline images are an ordered, unlabelled sequence, and the order is not the
candidate order.** A session rendered a proof sheet from them, renamed the files
`f_01…f_13` and stated they were in card order; they were chronological, `f_01`
was card 13, and thirteen verdicts landed on the wrong thirteen frames. Caught
only because the reviewer SHA-256'd each file against the frame indices.
MEASURED on the wire: `inlineImages.frames` comes back `[2388, 2367, 2372]`
(confidence rank) while `candidates` starts `[1194, 1272, 1282, …]` (frame
order). The mapping was already emitted; the note now says the orders differ,
that the nth image is `frames[n]`, and not to renumber a rendered sheet 1..n.
The written PNGs were never affected — they are named `_f<frame>.png`.

**Classifier confidence is a rank and the app's filter turns it into a gate, so
the gate now names its cost.** MEASURED: clip 0012 frame 1272 is a genuine
distant bolt striking a far ridge through rain — frame 1271 is empty — and it
scores 0.0044 with a Y max of 945, indistinguishable from a no-event frame. Any
sane-looking floor throws it away and reports nothing missing. That is the honest
limit on "classification beats luminance" (#504): it beats it on RANKING what you
already have, not on RECALL. The slider stays, and it still starts at zero.

### The teaching lesson quoted a number off a baseline rule the engine does not apply

#740's last owed edit, and the edit found a fifth defect of the same family.
`Coaching.luminanceIsNotLightning` is the one judgment Walk renders without a
criteria file, on the grounds that it is Walk's OWN MEASUREMENT and not anyone's
taste. That is a claim about provenance, and nothing checked it.

**MEASURED, whole-clip scan of 0012, 2,771 frames, Y stride 1.** Frame 2347
+36.030% linear / 0.3435, frame 2388 +3.689% linear / 0.6616 — all four
reproduce exactly. The Y-plane figure does not. The lesson said frame 2388 rose
**0.8%** and four other surfaces say **0.79%**; against the detector's own
local-median baseline the engine says **+0.8655%**. 0.79% is frame 2388 divided
by **frame 2387 alone** — a baseline rule nothing in the engine computes.

**Why it survived.** The number it travelled with agrees under both rules:
frame 2347 reads +6.02% either way (local median +6.0204%, previous frame
+6.0172%). A pair that looks self-consistent carried one figure off a rule the
engine does not apply, and no reader could have known which rule was in play
because neither was named. Same shape as the rest of #740.

The lesson now states both spaces, quotes the engine, and adds the fact that
makes the point better than any threshold story: **on the gamma-encoded Y plane
frame 2388 is not a candidate at all** — +0.87% is under the detector's own 1%
floor, while on the linear plane it is one of 13. It also drops an unverifiable
claim: "a 6-sigma luminance threshold correctly rejected it as noise" appeared
exactly once in the repository, nowhere corroborated, against a detector whose
default is 12σ, and does not reproduce — frame 2388 sits at 147σ linear and 91σ
on the Y plane against the engine's own robust sigma.

`KnownAnswerTests.theLuminanceLessonQuotesTheEnginesOwnNumbers` re-derives all
five figures from a scan and judges the prose **in both directions**: a number
the engine did not measure fails, and a number the engine measured that the
prose omits fails. Proven able to fail — and the first draft of it could not.
The detail mentions the Y figure twice, so changing one mention to 0.79% still
satisfied a `contains` check and the test passed on prose written to be
rejected. A test that only detects the last wrong copy is the defect it guards,
one level up.

**Not corrected here, and named rather than left to be found:** `README.md`,
`Sources/walk/Commands.swift`, `Sources/walk-mcp/Tools.swift` and
`App/WalkApp/ProofSheetView.swift` all still print +0.79%. They are outside this
task's scope (#721 is open in two of those files) and each needs the same
engine-derived treatment.

### The CLI had no install target at all — task #729

**MEASURED on the operator's host:** `walk --version` reported **0.3.0** while
`walk-mcp --version` reported **0.5.0**, from one source tree. The Makefile had
an `install-mcp` target and **no install target for the `walk` CLI**. The front
door with an install path stayed current; the one without it drifted two
releases, silently. `make clean` deletes the release directory the stale binary
was copied from, so nothing on the box could say what build it was.

Not cosmetic. `walk contract --expect 0.5.0` **exited 1** (measured), so Pixel's
skill section 8.5 version gate read as FAILING for a reason that had nothing to
do with the skill — the gate was right and there was no path to fix what it
found. And `walk contract` listed **zero `coach.*` capabilities** (measured)
while walk-mcp told the same host they were declared: one host, two front doors,
two contracts.

`make install-cli`, and `make install` for both doors in one command, because
two separate targets leave "did you do the other one?" to memory — which is how
0.3.0 and 0.5.0 came to sit side by side. #740's check moved out of `install-mcp`
into `.github/stage-binary.sh`, which both targets call: **that check living in
one target is what let the other drift, and a copied check can diverge.** It
keeps #740's two failure modes (blank version, disagreement with
`Sources/WalkKit/Version.swift`) and adds two the inline version could not
express — a build that is not there, and a `Version.swift` that declares no
version. `install-cli` then runs `walk contract --expect <declared>`, the exact
command Pixel's gate runs, so an install that silently does not update is
impossible rather than unlikely.

Proven able to fail: `stage-binary.sh --selftest` requires all four failure
modes to fail and the matching case to pass, wired into CI as "Install check can
fail" beside the doctrine selftest. **Its own first draft resolved the version
source at load time**, so the fixture override did nothing and four of five
cases passed against the real 0.5.0 rather than the fixture — passing for the
wrong reason, in the thing whose whole job is catching that.

After: `walk` and `walk-mcp` both report 0.5.0, `walk contract --expect 0.5.0`
exits 0, and `walk contract` lists the `coach.*` entries. **No expected version
was lowered** — #729 forbids it and it is the defect the band is about.

### `walk-mcp --version` — the recorded regression did not reproduce

#740 recorded that `--version` printed nothing on 0.5.0 where 0.4.1 printed a
version, making `make install-mcp`'s success message report an empty version.
MEASURED against the binary the task itself names — 1,009,096 bytes, 13:46,
byte-identical to the release build: `--version` prints `0.5.0` and exits 0
through a TTY, a pipe, a `$(…)` substitution, a file redirect and with stdin
closed. The branch is untouched and nothing was changed to make it work.

**What DOES reproduce is adjacent and is the same defect class.** `--help`, `-h`,
an unknown flag and no arguments at all all printed nothing and exited 0. For no
arguments that is correct — it is a stdio server whose caller is a host — but
correct and crashed-on-startup were byte-identical from a prompt. So `--help`
answers, a hand-run server identifies itself on stderr, and an unrecognized
argument says it was ignored instead of being swallowed. stdout stays reserved
for the protocol and the ignore-and-keep-running contract is unchanged.

`make install-mcp` no longer echoes an unguarded `$(walk-mcp --version)`. It
captures the version, fails if it is blank, and fails if it disagrees with the
version declared in `Sources/WalkKit/Version.swift` — which also catches a stale
copy, where the binary identifies itself perfectly well as the wrong build. All
three paths proven: the happy one, a binary that prints nothing, and one that
reports 0.4.1. It also now says plainly that a registered stdio server keeps
running the old binary until the host restarts, which is how the operator came to
believe he was still on 0.4.1.

## 0.5.0 — 2026-09-12

**The MCP server told every consumer the opposite of the product's own
doctrine, in the one string guaranteed to be read first.** Fixed first, because
it was not merely stale — it suppressed the feature.

`walk-mcp`'s `instructions` string is the text an MCP host reads BEFORE it
chooses a tool, served on every connect. It read, verbatim:

> "It never renders a keep/pitch verdict — sorting and flagging is Walk's job,
> judgment is yours and the operator's."

**Decision #513 reverses that exactly:** Walk's output is a COACHING VERDICT,
not a measurement readout. So the server shipped prose describing a product
decision that had been overturned — this factory's most-repeated defect class,
prose describing a mechanism that no longer exists with nothing able to notice,
sitting in the most-read sentence the repository owns. And the failure mode is
worse than staleness: **a consumer told "never renders a verdict" does not ask
for one.** The defect was spotted during the 0.4.1 build and correctly left as
out of brief; it was in brief here (task #736).

It is now rewritten to state the doctrine AND the current absence, because
either half alone is a lie of a different kind. The same sentence was corrected
in four other places it had been copied to: `README.md`'s design rule 5, the
`walk scan` text output, the `walk scan --json` note, and `walk_scan`'s tool
description.

### The three bands (#513)

| Band | What it owes |
|---|---|
| **SELLABLE AS SHOT** | Good, and why — the craft a buyer is paying for, not the number |
| **HAS POTENTIAL, WITH THIS** | The one specific change, then *"Where did you want to go?"* |
| **NOT WORTH THE TROUBLE** | Why, plainly, so the tell is learned |

Every band carries a next-flight lesson. **Band 2's two halves are enforced in
`Coaching.Verdict`'s initializer, which throws** — a verdict with the change and
no question, or the question and no change, cannot be constructed. That is
deliberate: such a verdict would still render, still read like coaching, and
have quietly become a sorting label. Nine tests assert the refusals.

### The criteria file (#499), which is the missing mechanism

Decision #499 ruled that Pixel's hard-earned logic drives the verdicts and that
a Walk without it "is a light meter". 0.4.1 shipped the light meter because
there was no mechanism to produce a judgment. `Criteria` is that mechanism: a
versioned JSON file whose every rule carries #499's four fields — the
measurement, the threshold, the reason in language, and **the session or
decision that established it**. The loader refuses a rule missing any of them.

**No criteria ship with Walk, and every surface says so.** `coach.verdict` is in
`Walk.notImplemented` with a reason that names `app.proofSheet` as displaying
and not judging — the exact gap #513 identified, where the contract surface
built to prevent absence-reading-as-success declared a proof sheet and said
nothing about it not judging. `walk contract`, every `walk_scan` result and the
app panel all report `available: false`, the reason, and every path searched.

Four refusals, each because the alternative is a verdict that cannot be audited:

- a rule with no `origin` — field 4 is what lets a verdict cite its own source;
- criteria written against another Walk version — **no** verdict renders and the
  mismatch is reported, same discipline as `walk contract`;
- a candidate no rule covers — returned as uncovered and left **unjudged**,
  because a default band lets a thin criteria set read as a complete judgment;
- an unmeasured confidence — `null` is not `0`, so a rule reading one does not
  fire rather than firing on a false zero.

### What was NOT touched, and that is the point

The measurement layer was not the defect. 13 candidates out of 2,771 frames of
4K60 HLG in 29.5 s, with the statistical floor honestly reported as a threshold
rather than a verdict, is good and fast. #513 rejected removing it in terms:
**the measurements are the evidence UNDER a verdict, available and not
leading.** Every verdict lists the value it read and the threshold it was tested
against. Removing them would make the coach unfalsifiable. The JSON response
shape was measured as additive in 0.4.1 and it was: `coaching` was appended to
each clip and `coach` to the top level, nothing above them changed, and a 0.4.1
consumer reads these results unchanged.

### Readback, on real footage

MEASURED, clip `DJI_20260912051637_0012_D.MP4`, frames 2330–2400, with a
criteria file **labelled in its own `owner` field as a Carver fixture and not
photographic judgment** — the plumbing is proven, the content is not claimed:

```
COACHING VERDICT  2 SELLABLE AS SHOT · 5 HAS POTENTIAL, WITH THIS · 1 NOT WORTH THE TROUBLE

  SELLABLE AS SHOT
    frame 2367   evidence vision.lightning = 0.5581 (rule required atLeast 0.4500)
    frame 2388   evidence vision.lightning = 0.6616 (rule required atLeast 0.4500)
  HAS POTENTIAL, WITH THIS
    frame 2347   evidence vision.lightning = 0.3435 (rule required between 0.1000 and 0.4499)
                 Where did you want to go?
```

**Note which frames those are.** The fixture bands 2367 and 2388 as the best and
drops the brightest frame in the clip, 2347, into band 2 — which is #504
correcting #495 arriving in the output surface. Frame 2347 lifted the picture
36.0% and scores 0.34; frame 2388 lifted it 0.8% and scores 0.66. **Luminance
finds bright flashes; classification finds lightning.** Sorting by brightness
picks the wrong frame, and the first scan of this clip lost two real
cloud-to-ground strikes that way. That lesson ships as
`Coaching.luminanceIsNotLightning` with its measured numbers, its origin, and a
test asserting the numbers — and it is reported **even when no verdict can be**,
because it is Walk's own measurement rather than anyone's taste.

### Added

- `WalkKit/Coaching.swift` — bands, the throwing verdict initializer, the
  evidence trail, the report with its honest-absence path, the lesson.
- `WalkKit/Criteria.swift` — the criteria file: schema, resolution order
  (explicit → `WALK_CRITERIA` → Application Support), validation, staleness.
- Capabilities `coach.bands`, `coach.criteria`, `coach.evidence`; absence
  `coach.verdict` with its reason.
- `criteria` argument on `walk_scan` / `walk_scan_folder`; `--criteria` on
  `walk scan`; `coaching` per clip and `coach` at the top level of every result;
  a coaching block in `walk contract` and in the app's proof sheet.
- `ClipScan.Candidate` gained a public initializer so the CLI hands its own
  findings to the same coach instead of growing a second judgment layer.
- 79 tests, 27 of them new and most of them asserting a refusal.

### Not done, and named rather than left to be discovered

- **The criteria content.** Pixel's judgments on clip 0012 were being written to
  `artifacts/walk/clip-0012-verdicts.md` while this shipped and had not landed
  when it was tagged. #499 reserves the judgment to her; authoring photographic
  criteria here would have been the one thing this build was told not to do. The
  shape is ready and `Coaching.shippedCriteriaJSON` is `nil`, **tied by a test
  to the `coach.verdict` absence in both directions** so criteria cannot ship
  quietly with a contract still denying them.
- **The o-MATIC mark on the sheet.** #513 also recorded that the sheet carries no
  o-MATIC identity. Not attempted: the mascot shape is Tier 0 and drawing one
  from a description is forbidden, so it belongs with the brand work rather than
  here.

## 0.4.1 — 2026-09-12

**The front door's headline gesture returned 50k tokens of JSON.** Measured
immediately after 0.4.0 was tagged, by serializing what a real call actually
hands back rather than by looking at the code.

A full walk of the operator's own GoPro folder — the exact gesture #507 is
about, `walk_scan_folder` over 8 clips — produced **201,889 bytes**, roughly
**50,000 tokens for one tool result**. The default per-clip candidate ceiling
was 200 and the folder holds 235 candidates across 8 clips, so nothing trimmed.

That is not a correctness defect; every number was right. It is worse in a
particular way: the tool whose whole purpose is *"go walk this folder while I'm
talking to the coach"* would spend a quarter of the conversation's context on
its first use, on rows nobody asked to read.

**Fixed by rationing rows, never counts.**

- `walk_scan_folder` defaults to **10 candidate rows per clip**. `walk_scan`
  keeps 200 — one clip is where reading everything is affordable.
- **Trimming is by RANK, not by frame order.** `prefix()` would have kept
  whichever candidates sit earliest in the clip. Across those 235 non-storm
  candidates the highest `lightning` confidence is **0.0010** and on the storm
  clip it is **0.6616**, so the confidence is precisely the axis that separates
  them — discarding it to preserve frame order would throw away the only signal
  that makes a short list readable. Rows are selected by lightning confidence,
  then by luminance rise, then sorted back into frame order so a reader can
  still follow the clip.
- When classification is off it ranks by luminance rise and **says so**, in
  `candidatesSelectedBy`. `candidateCount`, `candidatesReturned`,
  `candidatesTrimmed`, the verdict, the thresholds and the per-clip diagnostics
  always describe **every** candidate found.

MEASURED after, same folder, same 42,728 frames:

```
payload        201,889 -> 54,665 bytes   (-73%)
candidates     235 found, 51 rows returned, counts unchanged
GX010042       count 100  returned 10  trimmed  by: highest lightning confidence
GX010040       count  15  returned 10  trimmed  by: highest lightning confidence
GX010035       count   0  returned  0  NOTHING FOUND
GX010041       count   0  returned  0  NOTHING FOUND
```

The single highest-confidence row returned anywhere in the trimmed result is
GX010040 frame 413 at 0.0010 — the highest-confidence candidate in the entire
non-storm set. The ranking kept the right frames.

### Changed

- `walk_scan_folder` default `max_candidates`: 200 → 10 per clip.
- New field `candidatesSelectedBy` on every clip result.
- 52 tests: one asserting that `FolderResult` distinguishes *nothing to
  scan* from *nothing found* — conflating those is how "we found nothing" comes
  to mean "we did not look" — and one asserting that a cancelled scan stops
  rather than finishes.

### AND A CLAIM OF MY OWN THAT DID NOT SURVIVE ITS OWN READBACK

0.4.0's changelog and commit message both said:

> `notifications/cancelled` actually cancels — `Running` holds the in-flight
> tasks — because acknowledging a cancellation and continuing to decode is a
> success signal with nothing behind it.

**Measured: it did not cancel.** The notification arrived, `Running` found the
task, `Task.cancel()` set the flag — and the decoder ran to the end of a
15,367-frame clip anyway, because the only `checkCancellation()` in the path sat
in `ClipScan`'s candidate loop, which runs *after* the scan. Acknowledged, and
nothing stopped. The sentence describing the control was the control's only
evidence, which is the defect this repository is named for.

Found by driving the live server with a reader thread running from t=0 and
timestamping receipt, rather than by reading the code.

Two fixes:

- **`FrameScanner` checks cancellation per frame.** One flag read against ~2.6 ms
  of decode and Core Image work per frame is not measurable.
- **A cancelled request gets NO reply.** The stdio binding says a server "MUST
  NOT send any further messages for it", and the previous code would have
  answered with `isError: true` — a response the client has no request left to
  correlate. `Running.run` returns `nil` for a cancelled task and the dispatcher
  sends nothing. The app treats `CancellationError` as a clean stop rather than
  a failure to report.

MEASURED after, on the live server over stdio:

```
0.21s  initialize -> replied            (legacy, agreed 2025-11-25)
3.00s  ping sent at 3.00s -> replied    DURING the scan
4.01s  walk_contract sent at 4.00s -> replied   DURING the scan
6.01s  notifications/cancelled received
6.04s  work stopped, no reply sent
```

**Concurrency is therefore measured and not asserted:** a `ping` and a
`walk_contract` both answered within 10 ms of being sent while a 15,367-frame
4K scan was in flight. And cancellation stops the work in **30 ms**, where
before it ran to completion. A test pins both the `CancellationError` and the
elapsed time, because a cancellation that is merely *reported* is the thing that
was wrong.

### And two more controls, because the prose is what a consumer reads first

`.github/check-tool-docs.py` compares the README's tool block against the LIVE
`tools/list` schema, both directions: a parameter the server takes that nobody
documented, and a parameter the README names that no tool has. Currently
5 tools, 45 parameters, none undocumented and none invented — and both failure
directions were proven before it was accepted.

And the README states a test count, so **the test count is checked**. It drifted
three times inside 0.4.0 alone — 48, then 50, then 51 — and each time it was
corrected by hand, which is the part that does not scale. CI now reads the count
out of the test log and compares it, and reports the skip count alongside,
because the known-answer tests cannot run on a CI runner and a green badge must
not read as a verified known answer.

The same defect class as everything else in this workflow. A README documenting
`--frames` after it became `from_frame` is a retired KB number cited as live
authority, with a smaller blast radius and a wider audience.

### One more silent wrong answer, removed

`walk_segments` dropped a frame range when `to_frame` was missing or not greater
than `from_frame` — and then scanned the whole clip. A caller who asked for
frames 2300 onward and got the entire file back had no way to tell: a different
answer to a different question, returned without comment. It now refuses, the
way `walk_scan` already did. Both refusals measured.

### Still true, and still the caveat that matters more than the result

54,665 bytes is about 13.7k tokens for 8 clips of 4K footage. Better, not
small. The candidate rows still dominate it, and the reason a folder walk is
expensive at all is unchanged: **the detector finds one kind of event**, so 235
brightness changes come back where a sort of interesting moments was wanted.
Trimming by lightning confidence makes a single-event detector's output
readable; it does not make it a sort. #498's distance is unchanged.

---

## 0.4.0 — 2026-09-12

**The conversation reaching the engine.** A third executable target, `walk-mcp`,
serves WalkKit over MCP stdio. One library, three front doors — the `walk` CLI,
`Walk.app`, and now an MCP server, which decision #507 makes the primary one.

Operator ruling, #507, verbatim: *"that's what i'm going for, not an outside app.
tell you go walk this folder while i'm talking to andy, and you tap in to the
local resources to get it done? see ?"*

---

### The tool surface

Five tools, designed for a model to reason over rather than a person to read.
Every result carries `structuredContent` and the same JSON serialized into a
text block, per the spec's backward-compatibility note.

| tool | what it returns |
| --- | --- |
| `walk_scan` | one clip: per-candidate frame, timecode, seconds, luminance rise, rise in the clip's own sigma, Y-plane mean and max, Vision confidences, thumbnail path |
| `walk_scan_folder` | the operator's own sentence. Per-clip results plus what was searched, skipped, unreadable, and which clips returned nothing |
| `walk_segments` | cut ranges with handles; shortfall reported, never clamped. Writes verified HEVC Main10 HLG when given `out_dir`, otherwise returns the plan |
| `walk_grade` | the still grade with before, after, and the cast check. `output` optional — measuring without writing is a legitimate answer |
| `walk_contract` | version, every capability with the version that introduced it, every ABSENT capability **with a reason**, and the MCP protocol versions |

A contract mismatch comes back as `isError: true`, not as a field inside a
success. The point of the contract is that a stale consumer fails loudly; a
quiet `ok: false` is something a model reads past.

### DUAL-ERA, AND THAT WAS NOT CAUTION — IT WAS A MEASUREMENT

The current MCP revision, **`2026-07-28`**, removed the `initialize` handshake.
Servers **MUST** implement `server/discover`, every request declares its version
in `_meta["io.modelcontextprotocol/protocolVersion"]`, and an unsupported
version comes back as `UnsupportedProtocolVersionError` (**-32022**). Revisions
up to `2025-11-25` are what that page calls *legacy*, and they handshake.

MEASURED 2026-09-12 by capturing the real wire with `WALK_MCP_LOG` while Claude
Code launched the binary:

```
>> {"method":"initialize","params":{"protocolVersion":"2025-11-25",
     "clientInfo":{"name":"claude-code","version":"2.1.258", ...}},"id":0}
>> {"jsonrpc":"2.0","method":"notifications/initialized"}
>> {"method":"tools/list","jsonrpc":"2.0","id":1}
```

No discover probe. No per-request `_meta`. **The host that has to register this
server speaks the legacy era.** A server written to the current specification
alone would not have connected at all — and would have failed with the host
looking broken rather than the server. The spec's own compatibility matrix says
a dual-era server works with both client eras, so both are implemented, and CI
replays that captured exchange verbatim so it stays true.

### THE CONTRACT LIE, RESOLVED — AND IT WAS AMBIGUITY, NOT A FALSE ENTRY

#507: the operator dropped a folder into Walk.app, it walked eight clips, and
`ingest.dump` was sitting in `Walk.notImplemented` the whole time.

MEASURED cause: `ProofSheetModel.open(_:)` held its own `contentsOfDirectory`
call and its own private `videoExtensions` set. **The app walked folders; the
library did not have the code and so could not declare it.** Contract drift
inside the version contract — the exact defect the contract exists to catch.

Fixed on the side that was wrong, which was the library:

- **`ClipFinder`** now owns folder enumeration, in WalkKit, with 8 tests.
  `ingest.folderScan` is declared at 0.4.0.
- **`ClipScan`** owns the read → scan → detect → classify sequence that existed
  three times over — in the CLI, in the app, and about to be a third time in the
  MCP server. `scan.clip` at 0.4.0.
- The app calls both and holds no folder logic. **CI fails** if `contentsOfDirectory`
  or `FileManager.default.enumerator` reappears in any front door outside a comment.

**`ingest.dump` STAYS ABSENT, and that is the honest answer.** The bare name was
doing two jobs at once: *enumerate a folder*, which existed, and #496's *"go
through my dump for me"* — rank a mixed dump by interest — which does not. A
one-word entry cannot distinguish those, so it was read as a flat denial. The
resolution is not to edit the list until it agrees with the app:

- `ingest.folderScan` — **present.** Enumerates and scans.
- `ingest.dump` — **absent.** Ranking. Its reason now names `ingest.folderScan`
  explicitly, and a test asserts it does.
- `ingest.triage` — **new absent entry**, so the general-interest detector
  (#498) has a name of its own and stops hiding inside `ingest.dump`.

### Every absence now owes a reason

`Walk.notImplementedReasons` is new, printed by `walk contract` and returned by
`walk_contract`. Tests assert the map is complete, that no reason exists for a
capability that IS present, and that `ingest.dump`'s reason names what does
exist. CI asserts it through the shipped binary, because #507's defect was a
consumer reading the contract output and believing a bare word.

### TWO CAVEATS FROM 0.3.0 ARE DISCHARGED — BY REAL USE, MEASURED HERE

Reproduced through the MCP front door on the operator's own GoPro folder,
8 clips, **42,728 frames**, 235 candidates, 235 thumbnails, zero failures,
26 `.THM` sidecars correctly skipped:

```
GX010035.MP4      296 frames  277.0 fps  thr  1.0000% floor        0 cand  NOTHING FOUND
GX010036.MP4    15367 frames  313.4 fps  thr  5.7069% statistics  38 cand
GX010037.MP4     3383 frames  314.3 fps  thr 11.7545% statistics  31 cand
GX010038.MP4     6926 frames  314.4 fps  thr  3.8566% statistics  50 cand
GX010039.MP4     3477 frames  315.2 fps  thr  4.7007% statistics   1 cand
GX010040.MP4     5256 frames  316.3 fps  thr  7.0685% statistics  15 cand
GX010041.MP4       99 frames  273.7 fps  thr  1.1920% statistics   0 cand  NOTHING FOUND
GX010042.MP4     7924 frames  317.8 fps  thr  8.8030% statistics 100 cand
```

**1. The honest-empty path.** 0.3.0 recorded it as proven by unit test only. It
has now run on real material twice — and `GX010041` closes it better than #507's
`GX010035` did, because 0035 is **floor** bound and 0041 is **statistics** bound.
Both halves of `max(statistical, floor)` have produced an honest empty on real
footage.

**2. The statistical threshold.** 0.3.0 recorded it as unexercised: on all six
storm clips the 1% floor bound, and on two the MAD estimator collapsed to exactly
zero. Seven of eight GoPro clips are statistics bound, none collapsed, and one of
them returned nothing while statistics bound. No longer a guard against a case
that did not occur.

The counts for 36, 37 and 38 match #507's reading of the operator's screenshot
**exactly** — 38 over 15,367, 31 over 3,383, 50 over 6,926. The MCP front door
reproduces the app's numbers frame for frame, which is the evidence that it is a
wrapper and not a second implementation.

### A NEW MEASUREMENT, AND IT NARROWS THE GAP WITHOUT CLOSING IT

Across all 235 candidates in that non-storm footage, **the highest `lightning`
confidence is 0.0010** — GX010040 frame 413. On storm clip 0012 nine candidates
score ≥ 0.078 and the top reads **0.6616**. A separation of roughly 660×.

So the classifier confidence already tells a reader, loudly, that a GoPro
candidate is not lightning. What is missing is not a better signal on THIS axis;
it is that **nothing ranks on it**, and knowing a frame is not lightning is not
the same as knowing it is interesting. 235 brightness changes with
`lightning ≈ 0` are still 235 unranked brightness changes. #498 is not closer to
done; its distance is just better described. **The detector was not widened, per
#507.**

### The deprecation control was narrow and read as broad

0.3.0's CI step greps the build log for `deprecated in macOS 27`, which was that
release's whole job, and it passed. Decision #504 then recorded *"Zero
deprecation diagnostics, and CI fails if one returns."*

MEASURED while building 0.4.0: **that is not true of the build as a whole, and
was not true of 0.3.0 either.** v0.3.0's own green run (34701326745, Swift 6.3.3,
SDK 26.5) emitted **58 diagnostic lines** of a different deprecation — Core Image
Kernel Language, `CIColorKernel(source:)`, deprecated since macOS 10.14 — and
passed, because the control was narrow and nothing looked wider. The control was
true; the sentence about it was not.

So the control is now **the inventory, not the keyword**.
`.github/check-deprecations.sh` extracts every deprecation in the build and
compares it against `.github/deprecations-allowed.txt`:

- a diagnostic not in the allowlist **fails**
- an allowlist entry that no longer occurs **also fails**, because an allowlist
  keeping entries nobody has re-checked rots exactly the way a retired KB number
  cited as live authority rots

Both directions were proven to fail before the build was accepted.

**The CIKL deprecation stands, recorded rather than resolved.** Both colour
kernels are rational functions not expressible with built-in `CIFilter`s, so the
supported replacement is a Metal kernel — `.ci.metal` compiled with `-fcikernel`,
linked with `metallib -cikernel`, loaded through
`CIColorKernel(functionName:fromMetalLibraryData:)`. SwiftPM has no native Metal
compilation, so that is a build-tool plugin, a metallib resource and the Xcode
app target resolving it through the package bundle. A real structural change,
inherited from 0.1.0, not born here, and out of scope for a release whose job is
the front door. Owner recorded; the AVFoundation precedent is that Apple does
eventually remove what it deprecates.

A related judgment, stated because reversing it would look like a tidy-up: the
`nonisolated(unsafe)` annotations on both kernels now warn as *unnecessary* on
Swift 6.4, because `CIColorKernel` became `Sendable`. They are **kept**. CI runs
Swift 6.3.3, and those annotations exist because the v0.2.0 tag was cut on a red
run whose failure was *"static property 'kernel' is not concurrency-safe"*.
Removing a warning here by re-introducing that error is not a trade worth making.

### The Makefile target that failed for the right reason

`make deprecations` first reused the shared scratch path, so the build was
incremental, the compiler re-emitted nothing, the inventory came back empty, and
the allowlist looked stale. It failed loudly rather than passing on emptiness,
which is the correct way round — but it was still wrong, and it is the same trap
the CI workflow already comments on at its Build step. Fixed by wiping a
dedicated scratch path first: **the log only ever says what the compiler was
asked to compile.**

### A FALSE SHORTFALL, FOUND BY READING BACK A SEGMENT

`walk_segments` on clip 0012 frames 2300–2400 with one-second handles reported:

```
tail short 0.099 s (asked 1.00, clip offered 0.901)
```

**The clip did not offer 0.901 s. The clip has ~2771 frames and a full second
after frame 2388 is entirely available.** The shortfall was the SCAN WINDOW,
attributed to the clip.

Cause: 0.3.0's CLI clamped the segment builder against the decoded frame count,
with a comment saying so — *right for a whole clip*, because the container
estimate can be wrong, and *wrong for a sub-range*, where the decoded count is
the size of the window and says nothing about the clip's length. The new front
door inherited it and surfaced it in structured JSON, which is how it was seen.

A shortfall report that misnames its own cause is worse than no report, because
the entire reason `SegmentBuilder` carries a shortfall is so a short cut can be
explained. `ClipScan.Result.segmentClamp` now picks the basis from what was
actually scanned and **says which** — `measured` over a whole clip, `container
estimate` over a sub-range — and both front doors use it. `walk_segments`
returns the clamp and its basis alongside the segments.

After: frames 2274–2449, 175 frames, 2.920 s, lead 1.001, tail 1.902,
**full handles, 0 short**. Two tests pin both halves, and `SegmentsCommand` now
runs through `ClipScan` so the sequence is not a third copy there either.

### Also measured through the MCP surface

- **`walk_scan`** on clip 0012 frames 2300–2400, stride 1: frame 2347 reads
  **439.098**, the reference value, through the new shared orchestration.
  9 candidates, 1.484% threshold, statistics bound, 81.2 fps with exact Y.
  `inline_images: 2` ranked **frames 2388 (0.6616) and 2367 (0.5581)** to the
  top — the two frames #504 recorded Probot confirming visually as real,
  distinct cloud-to-ground strikes.
- **`walk_segments`** written before the clamp fix above: 115 appended, 115
  decodable, verified, **3.8333 s at exactly 30.00 fps**,
  hvc1 10-bit `ITU_R_2100_HLG`, 61.5 MB — the integer-rational retime from 0.3.0
  holding through a new front door.
- **`walk_grade`** on a 36.6 MP still: system gamma 0.780 at 100 nits, dramatic
  spread +0.0030, neutral −0.0143, both within the cast threshold. Measure-only
  mode (no `output`) works.
- **Inline image cost**, the number behind the thumbnail decision: 240 KB on
  disk, **316,984 and 318,076 bytes of base64** for two frames.

### Added

- `walk-mcp` executable target: `JSON.swift`, `Transport.swift`, `Server.swift`,
  `Tools.swift`, `main.swift`. **No package dependencies** — MCP over stdio is
  newline-delimited JSON-RPC 2.0, and an SDK would add a second version contract
  to keep in step with this one by hand, which is the thing §8.5 exists because
  of. `--version` and `--selftest` for CI.
- `ClipFinder`, `ClipScan`, `ClipScan.folder`, `StillGrade`,
  `Frame.writeDisplayPNG`, `Walk.notImplementedReasons`.
- Capabilities: `scan.clip`, `ingest.folderScan`, `thumbnail.displayPNG`,
  `grade.still.api`, `contract.reasons`, `mcp.stdio` — all 0.4.0.
- `notImplemented`: `ingest.triage`.
- `.github/check-deprecations.sh`, `.github/deprecations-allowed.txt`,
  `.github/mcp-handshake.sh`.
- `make mcp`, `make mcp-check`, `make install-mcp`, `make deprecations`,
  `make verify`.
- **20 tests**, 50 total: `ClipFinderTests` (8), contract reasons and the #507
  resolution (5), `ClipScan` known-answer parity, thumbnail-is-not-a-measurement,
  folder-walk over the storm clips, and both halves of the segment clamp.

### Changed

- The still grade moved out of `Sources/walk/main.swift` into
  `StillGrade`. Every line of it — the colour-management-disabled load, the raw
  baseline, the NaN refusal, the managed re-measure, the cast check, the PNG
  write — was inline in the CLI and unreachable from another target. No number
  changed; the CLI now formats what the library measures.
- `walk contract` prints the reason under each absent capability. CI's
  disjointness parser keys on **indentation** rather than field count, because
  an `awk NF==1` parser would have started matching wrapped prose.
- Concurrency: each MCP message is handled on its own task, writes serialized by
  a `Wire` actor. A folder scan is minutes of work; a host that could not get a
  `ping` answered or a `notifications/cancelled` delivered during one has no way
  to tell a long scan from a hung process.
  **This release ALSO claimed that `notifications/cancelled` actually cancels.
  Measured, it did not — see 0.4.1.**

### Not in scope, and deliberately untouched

The single-event detector (#507, #498), passthrough (#721), Core ML (#722),
audio, FCPXML, the Andy rename, and the `Walk.app` distribution question. The
detector was **not** quietly widened while the front door was built.

### What could not be measured

- **A tool call driven by the host.** The handshake and tool registration were
  measured live against Claude Code 2.1.258 via
  `claude --strict-mcp-config --mcp-config`, which persists nothing. The run then
  failed OAuth before a tool call — a nested-CLI limitation, not a `walk-mcp`
  fault. Every tool was exercised over the raw wire instead.
- **`claude mcp add` was not run.** It writes host configuration. `make
  install-mcp` stages the binary and prints the command; running it is the
  operator's.
- Sustained and thermal load. Passthrough correctness. Audio. Custom Core ML.
  Whether a general-interest detector is achievable at acceptable cost —
  inferred, per #507, and still not scoped.

---

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
