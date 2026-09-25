# phot-o-MATIC

**An on-device photographic and video engine for macOS, reachable from a
conversation.** Measurement first, grading second, no third-party application
required.

You say *"go walk this folder"* while you are talking to the coach. The engine
runs here, on your own hardware, fast and free after install, and the numbers
come back into the conversation. That is the product — not an application you
open. The MCP server is the front door; the CLI and the app are the other two
ways in to the same library.

The engine is deterministic and carries no model; the judgment lives in the
coach. That separation is deliberate — a model upgrade must never silently
change a measured value.

---

## Why it exists

Grading a photograph well requires a loop: **measure → adjust → re-measure →
converge.** Most automation paths can adjust but cannot measure:

| Path | Read-back |
|---|---|
| **Core Image (phot-o-MATIC)** | full buffer, 24 MP in ~8 ms |
| Affinity `readPixel` | ~4.7 µs per pixel |
| Pixelmator `pick color` | one pixel per Apple Event |
| Screenshot / computer use | no real pixel data |

phot-o-MATIC owns the read-back, so the loop closes.

Video is the same argument at a different scale. Finding one bright frame in a
flight of storm footage means measuring every frame:

| Path | 2771 frames of 4K60 HLG |
|---|---|
| **AVFoundation + Core Image (phot-o-MATIC)** | 6.4 s at full 3840×2160 |
| `ffmpeg signalstats`, downscaled to 640 wide | 71.3 s — and it missed two strikes |

The downscale is what missed them: a fixed threshold after the resize put frames
2334 and 2340 below the bar. Full-resolution `ffmpeg` confirms both. That is why
the detector derives its threshold from the clip instead of carrying a constant
— and why the constant it still needs is named as one.

## What it does today

**Video**

- **Reads** 4K60 10-bit HLG BT.2020 frame-exactly — 430 fps of decode plus
  whole-frame measurement, measured on 2771 frames of the operator's storm
  footage
- **Scans** every frame for whole-image luminance in pinned linear BT.2020
  light, 1.87 ms per 8.3 MP frame
- **Detects** events from the clip's own statistics with a named absolute floor,
  and can report *nothing found* honestly
- **Classifies** a candidate with Vision's built-in taxonomy — 1303 identifiers,
  no model file, `lightning` among them
- **Cuts** segments with handles, reporting any shortfall rather than clamping
  quietly
- **Writes** HEVC Main10 + HLG, retimed so a one-frame event survives a 60→30
  conform, and re-reads what it wrote to prove nothing was lost

**A folder, shown**

- **A time-sampled proof sheet** over mixed media — every still one cell, every
  clip a strip of frames spaced evenly across its whole duration. Distinct from
  a scan: a candidate is a luminance event, so a clip whose light never changes
  produces no candidates and no picture, and two of eight GoPro clips did
  exactly that. Sampling *time* gives every clip a picture of its arc.
- **Progressive.** The manifest is written before a single pixel is decoded and
  rewritten atomically as cells land, and every cell carries a tiny tone-mapped
  placeholder inline. Measured over the operator's DJI card — 8 clips, 2 JPG,
  1 DNG, 5.8 GB: the layout is on disk at 0.73 s, all 99 placeholders by 4.5 s,
  all 99 sharp cells by 11.0 s.
- **Every cell carries its evidence** — frame index, timecode, seconds,
  dimensions, fps, duration, codec, transfer function and the tone map that was
  applied. For a DJI clip with a sibling `.SRT`, the shutter and ISO
  *distribution over the whole file* — never frame 1, where the aircraft is
  still settling — and a 180-degree shutter comparison against 1/(2 × fps).
- **phot-o-MATIC emits the data, not the page.** There is no HTML, no CSS and no styling
  in the engine; `manifest.json` is the artifact and the viewer is separate.
- **It displays and measures. It does not judge.** Nothing is banded, ranked,
  scored or sorted by interest, and the shutter comparison is a measurement
  against a named convention rather than a verdict on the footage — see design
  rule 5 and `ingest.dump` in `walk_contract`.

**Stills**

- **HLG → SDR conversion** (ITU-R BT.2100 / BT.2390) with a filmic tone map
- **Whole-image measurement** — mean channels, luma, and a colour-cast check
- **A grade that reports what it changed**, and refuses to run without a baseline

**From a conversation**

- **An MCP server over stdio** — `walk_scan`, `walk_scan_folder`,
  `walk_proof_sheet`, `walk_segments`, `walk_grade`, `walk_contract`. Structured JSON per candidate,
  a written PNG path per candidate so a frame can be *shown* rather than
  described, and the version contract exposed through the same surface so a
  consumer can verify the server against the library it wraps.
- **Dual-era protocol.** The current MCP revision (`2026-07-28`) removed the
  `initialize` handshake in favour of `server/discover` and per-request
  metadata. Measured 2026-09-12: Claude Code 2.1.258 still opens with
  `initialize` at `2025-11-25`. phot-o-MATIC answers both, and CI replays the captured
  Claude Code exchange so that stays true.

**What it will never do** — see design rule 5.

## Usage

```
walk scan <video> [--json] [--frames a-b] [--no-vision] [--fast]
                  [--sigma <k>] [--floor <fraction>]
walk segments <video> [--handles <sec>] [--lead <sec>] [--tail <sec>]
                      [--out <dir>] [--fps <n>] [--dry-run]
walk sheet <folder> [--out <dir>] [--frames <n>] [--cell-width <px>]
                    [--recursive] [--no-placeholders] [--max-items <n>] [--json]
walk identifiers [substring]
walk <input> <output> [neutral|dramatic] [targetNits]
walk contract [--expect <version>]
walk --version

walk-mcp                        # MCP server over stdio; a host launches it
walk-mcp --version              # prints the version and exits
walk-mcp --help                 # says it is a server, not a command
walk-mcp --selftest             # names its transport, protocols and tools
```

Run `walk-mcp` by hand with no host and it reads end-of-file and exits, printing
nothing on stdout — stdout belongs to the protocol. That is success, and it used
to be indistinguishable from a crash, so a hand-run server now identifies itself
on stderr and `--help` explains what it is. An unrecognized argument is still
ignored rather than fatal — a host passing a stray flag must not lose its server
— but it now says on stderr that it was ignored.

### The MCP tools

```
walk_scan          path, from_frame, to_frame, vision, identifiers,
                   y_plane_stride, sigma, floor, thumbnails, thumbnail_dir,
                   thumbnail_width, inline_images, max_candidates, criteria
walk_scan_folder   path | paths, recursive, max_clips, + every walk_scan option
walk_proof_sheet   path | paths, out_dir, frames_per_clip, cell_width,
                   placeholder_width, jpeg_quality, placeholders, recursive,
                   max_items
walk_segments      path, handles | lead_seconds + tail_seconds, out_dir, fps,
                   from_frame, to_frame, vision, sigma, floor
walk_grade         input, output, look (neutral|dramatic), target_nits
walk_contract      expect
```

`walk_scan` defaults to `y_plane_stride: 1` — one clip is where exactness is
affordable. `walk_scan_folder` defaults to 4, and every result says
`yMeanIsExact` so an approximation is never compared against a reference. When
`vision` is off, confidences come back as `null` and never as `0`: a frame that
was not looked at is not a frame that scored nothing.

**Rows are rationed; counts never are.** `walk_scan_folder` returns 10 candidate
rows per clip by default (`walk_scan` returns 200), because a full walk of 235
candidates serializes to about 200 KB — roughly 50k tokens for one tool result.
When it trims it keeps the highest `lightning` confidence first, then the largest
luminance rise, sorts them back into frame order, and reports which in
`candidatesSelectedBy`. `candidateCount`, the verdict and the per-clip thresholds
always describe every candidate found.

```
$ echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"walk_scan_folder",
  "arguments":{"path":"/Volumes/NVMeExt1/Content/Photography/100GOPRO","max_clips":8}}}' \
  | walk-mcp
```
```
8 clips scanned, 42728 frames, 235 candidates — 2 clips returned nothing,
which is an answer and not a failure
```

```
$ walk scan DJI_20260912051637_0012_D.MP4
file          DJI_20260912051637_0012_D.MP4
video         3840 x 2160  (8.3 MP)  hvc1  10bit  59.94 fps  46.23 s  ~2771 frames  130.0 Mbit/s
colour        primaries ITU_R_2020  transfer ITU_R_2100_HLG  matrix ITU_R_2020   [HLG BT.2020]
working space kCGColorSpaceExtendedLinearITUR_2020  (pinned)
              The luma / base / delta / rise columns below are measured IN THIS SPACE.
              A gamma-encoded 10-bit Y-plane measurement of the same event is a DIFFERENT
              and much smaller number, and NOT by a fixed factor: clip 0012 frame 2347 is
              +36.03% here and +6.02% on the Y plane; frame 2388 is +3.69% here and +0.79%
              there. The Ymean and Ymax columns ARE Y-plane code values — they are not
              comparable with rise, and no single multiplier converts between them.
scan          2771 frames decoded in 29.993 s = 92.4 fps   CIAreaAverage 2.024 ms/frame
threshold     1.0000% relative rise   (statistics 0.3009% at 12σ, floor 1.0000%, floor bound)
robust sigma  0.000250782 of relative rise (MAD-derived). One figure per clip; per-candidate sigma
              is not printed (#740): it was rise divided by this constant, the rise column rescaled.
result        13 candidates over 2771 frames at a 1.000% threshold (floor bound)

  frame    timecode      time      luma      base     delta      rise   Ymean    Ymax  lightning  storm
   2334  00:00:38:54    38.939  0.472102  0.398456  +0.073645  +18.483%  427.783   1012     0.2112 0.2182
   2347  00:00:39:07    39.156  0.537254  0.394952  +0.142303  +36.030%  439.098   1007     0.3435 0.3516
   2388  00:00:39:48    39.840  0.385155  0.371452  +0.013703   +3.689%  414.238   1019     0.6616 0.6756
   ...

COACHING VERDICT  none rendered
  no criteria file. Decision #499 rules that Andy's hard-earned logic drives Walk's
  verdicts, and #513 that the output is a coaching verdict rather than a readout; the
  criteria file is the mechanism a verdict comes from and phot-o-MATIC does not ship one. The
  measurements are complete and unjudged. Install a criteria set at
  /Users/lucid/Library/Application Support/Walk/criteria.json, or name one with
  WALK_CRITERIA, and every scan renders bands from it.
  looked in:
    default: /Users/lucid/Library/Application Support/Walk/criteria.json

  The bands a criteria set fills:
    KEEPER
      Good, and why — the reason names the craft a buyer is paying for, not the number.
    HAS POTENTIAL, WITH THIS
      One specific change that would make it sell, then where you were going.
    NOT WORTH THE TROUBLE
      Why, plainly, so the tell is learned and not shot again.

  Luminance finds bright flashes. Classification finds lightning. They are different
  measurements.
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

## From a conversation

### As a plugin

phot-o-MATIC ships as an o-MATIC plugin, and **this repository is the
marketplace, not the plugin**. Claude Code refuses a repository that tries to be
both at once — a plugin `source` of `"."` is invalid — so the marketplace
manifest sits at the repository root and the pack sits one directory down, the
same shape as the other o-MATIC doors:

```
.claude-plugin/marketplace.json     the marketplace, at the root
.agents/plugins/marketplace.json    the same, for Codex
phot-o-matic/                       the pack: .mcp.json, .claude-plugin/,
                                    .codex-plugin/, skills/ and a prebuilt
                                    bin/walk-mcp — so a host installs it
                                    without a toolchain
```

```
claude plugin install phot-o-matic@phot-o-matic
```

**The six MCP tool names are still `walk_*`, on purpose.**
Walk was the development name. The tool names, the `WalkKit` module, the `walk` and
`walk-mcp` binaries and the criteria file's engine-version field are the stable
API and they did not move when the product was named; renaming them is a
breaking schema change and would get its own deliberate pass. What did change is
the *qualified* name a host composes from the plugin name — a saved permission
rule written against the old `mcp__plugin_walk_walk__*` form will no longer
match.

The floor is declared honestly in both manifests and **enforced in the
launcher**: macOS 26 or later on Apple silicon. There is no Intel build and no
port — the engine links Vision, CoreML and AVFoundation directly, which is why
the classification runs on the machine and costs nothing per frame.

A host that cannot run it does **not** get silence. `bin/omatic-walk-launch.sh`
falls back to a degraded MCP server that advertises zero tools and puts the
reason in its `instructions` string, because a spawn that simply dies is
indistinguishable from a plugin nobody has configured yet.

**Phase 1 ships the engine and no judgment.** No criteria set is inside the
payload, so every scan returns `coaching.available: false` with its reason and
the paths searched. Read that field; do not substitute a verdict for it.

To rebuild the payload from source:

```
make stage-plugin    # stages phot-o-matic/bin/walk-mcp and verifies what a host gets
make plugin-check    # the same verification on its own
```

`stage-plugin` calls `.github/stage-binary.sh` rather than copying the binary
itself, so the plugin binary cannot silently disagree with `Walk.version` —
that script's header records what happened the last time a front door had no
shared check.

### As a bare MCP server

```
make install-mcp     # copies walk-mcp to ~/.local/bin and prints the one command
claude mcp add --scope user --transport stdio walk ~/.local/bin/walk-mcp
```

`make mcp-check` replays both protocol eras against the built binary and
requires the refusals — an unsupported protocol version, an unknown tool, and a
consumer written against an older phot-o-MATIC. Set `WALK_MCP_LOG=<file>` in the
server's environment to capture every message in both directions; that is how
the era question above was answered rather than assumed.

**Thumbnails come back as paths, not bytes, and that was decided rather than
defaulted.** Measured on this material: a 640-pixel display PNG off a 4K frame
is about 240 KB, roughly 317 KB once base64-encoded, and one GoPro clip in the
operator's own folder produced 38 candidates — inlining all of them would be
around 12 MB of images for one clip. So every candidate carries a `thumbnail`
path and `inline_images` asks for a capped handful of the highest-confidence
frames as image content.

## The app

One window. Open a video or a folder, and it shows a proof sheet of what the
engine found — thumbnail, timecode, and the measured numbers behind each moment,
clickable for the rest. No preferences, no onboarding, no timeline editor.

```
make app     # builds App/Walk.xcodeproj
make run     # builds and launches it
```

`Walk.app --scan <path>` scans immediately, which is how the app gets verified
against known material instead of asserted to work.

## The verdict, and where it comes from

**Decision #513: Walk's output is a coaching verdict, not a measurement
readout.** The operator, on seeing the first proof sheet: *"the goal is to teach
and keep the user moving forward in their art. so you need to say these are
good, and why, these could be with this, where did you want to go? and these
ones aren't worth the trouble. The goal is sellable output. professional output.
make better photographers."*

| Band | What it owes |
|---|---|
| **KEEPER** | Good, and why — the reason names the craft a buyer is paying for, not the number |
| **HAS POTENTIAL, WITH THIS** | The one specific change, then *"Where did you want to go?"* |
| **NOT WORTH THE TROUBLE** | Why, plainly, so the tell is learned and not shot again |

Every band also teaches next flight — hover position, framing, exposure lock,
whether 60 fps for a 30 fps cut was right on a one-frame event. A verdict the
photographer cannot act on next time is a sorting label wearing a coach's voice.

Band 2 is the mechanism of the ruling and it is two parts, so **both are
enforced in the initializer rather than requested in a comment**: a verdict
carrying a change without the forward question cannot be constructed, and
neither can one carrying the question without a change. `CoachingTests.swift`
asserts each refusal. A band-2 verdict that lost either half would still render,
still read like coaching, and have quietly become a sorting label.

**The judgment is not in the code.** Decision #499: *"we need pixel experience
driving it"* — a phot-o-MATIC that does not carry her experience is a light meter. So the
bands are filled from a **criteria file**, and phot-o-MATIC ships none. `coach.verdict`
is in `walk contract`'s not-implemented list with that reason, every scan returns
`coaching.available: false` and says where it looked, and the app's proof sheet
states that it displays and does not judge. Absence is reported as absence.

Install one at `~/Library/Application Support/Walk/criteria.json`, name one in
`WALK_CRITERIA`, or pass `--criteria` / the `criteria` tool argument. Each rule
carries the four fields #499 requires, and the loader refuses a rule missing any
of them:

```json
{
  "criteria": { "version": "1.0.0", "walk": "0.5.0",
                "owner": "pixel", "established": "2026-09-12" },
  "rules": [
    { "id": "thin-bolt-fully-formed",
      "band": "sellableAsShot",
      "when": [{ "measurement": "vision.lightning", "op": "atLeast", "value": 0.45 }],
      "reason":     "...",   // field 3 — why, in craft language
      "origin":     "...",   // field 4 — the session or decision that established it
      "nextFlight": "..." }
  ]
}
```

`when` reads `vision.<identifier>`, `relativeRise`, `relativeRisePercent`,
`sigma`, `yMean`, `yMax` or `mergedFrames` with `atLeast`, `atMost`,
(`sigma` is still a rule selector for criteria files written against 0.5.x; it
is `relativeRise` divided by the clip's one robust-sigma constant, so a rule on
it is a rule on rise — it is no longer emitted on the sheet or the wire, #740)
`greaterThan`, `lessThan` or `between`. Order in the file is precedence; the
first rule whose every condition holds wins, and the verdict names it.

Four things it refuses, each because the alternative is a verdict that cannot be
audited:

- **A rule with no `origin`.** Field 4 is what lets a verdict cite where the
  advice came from, so the operator can check it rather than trust it. It is
  also the field that would have caught Pixel 2.2.0's reversed sign.
- **Criteria written against another phot-o-MATIC.** The file declares the version it was
  written for; a mismatch renders **no** verdict and reports the mismatch, under
  the same discipline as `walk contract`.
- **A candidate no rule covers.** It is returned as uncovered and left unjudged.
  A default band would let a thin criteria set read as a complete judgment.
- **An unmeasured value read as zero.** With `--no-vision` the confidences are
  `null`, not `0`, so a rule reading one does not fire at all.

The measurements stay, underneath. #513 kept them deliberately: removing them
would make the coach unfalsifiable. Each verdict lists the value it read and the
threshold it was tested against.

## The Xcode surface — development only, NOT how phot-o-MATIC ships

Open **`Walk.xcworkspace`** at the repository root. One window carries
`App/Walk.xcodeproj` and the root Swift package, so `WalkKit`, `walk`,
`walk-mcp`, the app and the tests are all visible and buildable together.

**THIS IS A DEVELOPMENT SURFACE AND NOTHING ELSE. phot-o-MATIC SHIPS AS AN o-MATIC
PLUGIN.** Decision #534 rules that, and it SUPERSEDED decision #508's
app-bundle mechanism in terms: an app cannot register its own MCP server, and
that install story is WITHDRAWN. The presence of an Xcode project here is not
evidence for it and must never be read as a route back to it — if a later
session finds this workspace and reasons "we could ship the .app", the answer is
already recorded and it is no.

**BUILD PRODUCTS MUST NOT LAND IN THIS REPOSITORY, AND ON THIS MACHINE THEY
TRY TO.** MEASURED 2026-09-14: a global Xcode preference
(`IDEBuildLocationStyle = Custom`, `IDECustomBuildLocationType =
RelativeToWorkspace`) sends every workspace's products to `<workspace>/Build`.
Here that is both inside `~/Documents` — an iCloud File Provider domain, where
codesign refuses and the failure reads as *"the bundle's executable couldn't be
located"* — and inside the published plugin root. One preference, two hazards.

Proven both directions, same command, same tree:

| | result |
|---|---|
| `xcodebuild test` without `SYMROOT` | **TEST FAILED**, 0 tests run, bundle would not load |
| `xcodebuild test` with `SYMROOT` outside iCloud | **TEST SUCCEEDED**, 142 tests in 223 s |

So use the Makefile targets, which pass `SYMROOT`/`OBJROOT` explicitly:

```
make xcode-build     # WalkKit via the workspace, products outside iCloud
make xcode-test      # the full suite from Xcode: 142 tests, ~210 s
```

`Walk.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` is committed to
steer the Xcode GUI toward the same place, but **it is not what makes these safe**
— measured, it does not override the global preference for `xcodebuild` and
silently no-opped. The Makefile is the control.

```
make payload-size    # what each install path actually carries, in bytes
make payload-check   # prove that assertion can fail (5 cases)
```

## Build

```
swift build -c release        # the library, the CLI and the MCP server
make test                     # 141 tests
make mcp-check                # both MCP protocol eras, refusals required
make deprecations             # the deprecation inventory against its allowlist
make app                      # the SwiftUI app (needs Xcode)
make verify                   # everything above, in CI's order
```

Requires **macOS 26** or later. The floor moved from 14 in 0.3.0 because the
classic `AVAssetReader` path is deprecated on macOS 27 and its replacement,
`AVAssetReaderOutput.Provider`, is `@available(macOS 26.0, *)`. There is no
build that is both non-deprecated and runnable on 14.

### Why there is a Makefile

This repository lives in `~/Documents`, an iCloud Drive File Provider domain.
The File Provider stamps `com.apple.FinderInfo` and
`com.apple.fileprovider.fpfs#P` onto bundle directories and `codesign` refuses
to sign a bundle carrying them — *"resource fork, Finder information, or similar
detritus not allowed"*. That one cause breaks both `swift test` under the Xcode
build system and `xcodebuild` of the app. `make` puts both build trees under
`~/Library/Developer/Xcode/DerivedData`, outside the synced tree. Plain
`swift build` and CI are unaffected.

## Known holes, named

- **The known-answer tests do not run in CI.** The material is 780 MB of the
  operator's archive on an external volume and cannot be committed. A test that
  runs only when the clip is *absent* prints exactly which checks were skipped,
  so a green run is not mistaken for a verified known answer.
- **~~"Nothing found" is proven by unit test, not by real footage.~~**
  **Discharged 2026-09-12.** `GX010035` (296 frames) and `GX010041` (99 frames)
  both returned nothing on real GoPro footage, and reported the threshold and
  which half of it bound.
- **~~The detector's statistical threshold never bound on real material.~~**
  **Discharged 2026-09-12.** Seven of eight GoPro clips are *statistics bound*
  where all six storm clips were *floor bound*, and `GX010041` is the case that
  closes it properly: the statistical half bound at 1.192% **and** returned
  nothing. Both halves of `max(statistical, floor)` have now produced an honest
  empty on real material.
- **The detector finds one kind of event.** It is a whole-frame luminance rise
  with a classifier attached. On non-storm footage a candidate is a brightness
  change — 235 candidates across 42,728 frames of GoPro footage, and the highest
  `lightning` confidence among all of them is **0.0010**, against 0.6616 on the
  storm clip. The confidence separates them cleanly; nothing yet *ranks* on it.
  `ingest.dump` stays absent for this reason and `walk_contract` says so.
- **A deprecation stands, recorded rather than resolved.** Core Image Kernel
  Language, deprecated since macOS 10.14, carries both colour kernels. The
  replacement is a Metal kernel, which means Metal compilation inside SwiftPM;
  not attempted in 0.4.0. It is in `.github/deprecations-allowed.txt` with a
  reason and an owner, and CI fails on any deprecation that is not.
- **Passthrough writing is not shipped.** Open defect task #721: 22 frames lost
  with every success signal returning true.
- **No audio.** Never read, retimed or written.
- **The coaching verdict does not reach a photograph.** phot-o-MATIC measures stills and
  shows them in a sheet; it cannot judge one. Of the seven selectors a criteria
  rule can read, exactly one — `vision.<identifier>` — transfers to a still with
  its meaning intact. `relativeRise`, `relativeRisePercent`, `sigma` and
  `mergedFrames` are all derived from neighbouring frames, and a photograph has
  no neighbours; `yMean` and `yMax` are 10-bit Y-plane code values off a planar
  buffer a still never produces. MEASURED 2026-09-12: a still hand-built as a
  candidate — the only route that exists — was banded NOT WORTH THE TROUBLE on a
  fabricated `relativeRise` of 0, with the evidence line reading *measured 0.0,
  held true*. Closing it is an engine-contract decision, not an implementation
  one; `coach.stills` in `walk_contract` carries the full reason.
- **A proof-sheet cell from a clip carries the filmic curve whether or not the
  clip is HLG.** `Frame.makeDisplayImage` has applied the Hable curve to every
  picture phot-o-MATIC writes since 0.3.0, and the sheet uses that same path rather than
  growing a second one. MEASURED 2026-09-12 on frame 450 of
  `DJI_20260913024928_0001_D.MP4`: phot-o-MATIC's path renders R52.5 G57.5 B62.0 against
  R60.8 G68.0 B76.8 for a plain managed HLG→sRGB conversion of the same frame —
  about 15% darker, which is the highlight rolloff doing what it is for. On an
  SDR source that curve is applied to footage that is display-referred already.
  Each item's `toneMap` field in the manifest names exactly what was applied, so
  a dark cell is readable as a transform rather than as the footage. Not
  changed here: altering a tested path shared with every candidate thumbnail is
  a separate decision with its own known answers to re-measure.
- **The placeholder is not the frame the sharp cell shows.** It is the nearest
  sync sample, because infinite seek tolerance is what makes the placeholder
  pass fast — 0.041 s/frame against 0.079 s. At 20 pixels, blurred, there is no
  visible difference, and the manifest's `placeholderContract.provenance` says
  so rather than leaving it to be assumed.
- **The app is not sandboxed.** The trade is stated in `WalkApp.swift`.
- **A handle shortfall over a partial scan is computed against the container's
  frame estimate, not a measurement.** Every segment result says which basis it
  used. Over a whole clip the figure is measured.
- **The MCP server was verified, but not registered.** The handshake and tool
  registration were measured live against Claude Code 2.1.258 using
  `--strict-mcp-config --mcp-config`, which persists nothing. A *tool call*
  driven by the host was not completed: the nested CLI run could not
  authenticate. Every tool was exercised over the raw wire instead. Persisting
  the registration is `claude mcp add`, which writes host configuration and is
  the operator's to run.

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
unmanaged image with no error. Colour tags survive an 8-bit buffer, so only the
Y plane proves bit depth. A missing `autoreleasepool` costs 6x and changes no
number. A retime ratio computed through a `Double` truncates 2000/1001 to
1999/1001 and passes every check except reading the duration. Each of those is
recorded where the workaround lives, not in a commit message nobody reads.

**5. phot-o-MATIC renders a verdict, and it is never derived from the metrics.**
Decision #513: the output is a coaching verdict in three bands, each carrying a
reason and a lesson for next flight. Session #228 is why the verdict cannot come
from the numbers — the operator's best-selling photograph fails nearly every
technical metric taken on it: 66.57% shadow, clipped at both ends, the highest
noise floor and the smallest file of the set. A tool that discarded his best
seller because it scored badly would be worse than no tool. So the judgment
comes from a criteria file carrying Andy's experience (#499), the measurements
sit underneath it as evidence, and where there is no criteria file there is no
verdict and the result says so. This README said the opposite until 0.5.0, and
so did the MCP server's own instructions string — see the changelog.

**6. Every finding declares how it was established.** Measured, inferred, or
reported. The changelog says which, every time.

## License

MIT © lucidIT LLC
