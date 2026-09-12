# Changelog

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
