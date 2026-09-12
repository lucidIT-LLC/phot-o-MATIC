# Walk

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
| **Core Image (Walk)** | full buffer, 24 MP in ~8 ms |
| Affinity `readPixel` | ~4.7 µs per pixel |
| Pixelmator `pick color` | one pixel per Apple Event |
| Screenshot / computer use | no real pixel data |

Walk owns the read-back, so the loop closes.

Video is the same argument at a different scale. Finding one bright frame in a
flight of storm footage means measuring every frame:

| Path | 2771 frames of 4K60 HLG |
|---|---|
| **AVFoundation + Core Image (Walk)** | 6.4 s at full 3840×2160 |
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

**Stills**

- **HLG → SDR conversion** (ITU-R BT.2100 / BT.2390) with a filmic tone map
- **Whole-image measurement** — mean channels, luma, and a colour-cast check
- **A grade that reports what it changed**, and refuses to run without a baseline

**From a conversation**

- **An MCP server over stdio** — `walk_scan`, `walk_scan_folder`,
  `walk_segments`, `walk_grade`, `walk_contract`. Structured JSON per candidate,
  a written PNG path per candidate so a frame can be *shown* rather than
  described, and the version contract exposed through the same surface so a
  consumer can verify the server against the library it wraps.
- **Dual-era protocol.** The current MCP revision (`2026-07-28`) removed the
  `initialize` handshake in favour of `server/discover` and per-request
  metadata. Measured 2026-09-12: Claude Code 2.1.258 still opens with
  `initialize` at `2025-11-25`. Walk answers both, and CI replays the captured
  Claude Code exchange so that stays true.

**What it will never do** — see design rule 5.

## Usage

```
walk scan <video> [--json] [--frames a-b] [--no-vision] [--fast]
                  [--sigma <k>] [--floor <fraction>]
walk segments <video> [--handles <sec>] [--lead <sec>] [--tail <sec>]
                      [--out <dir>] [--fps <n>] [--dry-run]
walk identifiers [substring]
walk <input> <output> [neutral|dramatic] [targetNits]
walk contract [--expect <version>]
walk --version

walk-mcp                        # MCP server over stdio; a host launches it
walk-mcp --selftest             # names its transport, protocols and tools
```

### The MCP tools

```
walk_scan          path, from_frame, to_frame, vision, identifiers,
                   y_plane_stride, sigma, floor, thumbnails, thumbnail_dir,
                   thumbnail_width, inline_images, max_candidates
walk_scan_folder   path | paths, recursive, max_clips, + every walk_scan option
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
working space kCGColorSpaceExtendedLinearITUR_2020  (pinned; the CIContext default is
              ExtendedLinearSRGB and measures 4.2x less of the event)
scan          2771 frames decoded in 29.174 s = 95.0 fps   CIAreaAverage 1.983 ms/frame
threshold     1.0000% relative rise   (statistics 0.3009% at 12σ, floor 1.0000%, floor bound)
result        13 candidates over 2771 frames at a 1.000% threshold (floor bound)

  frame    timecode      time      luma      base     delta      rise      sigma   Ymean    Ymax  lightning  storm
   2334  00:00:38:54    38.939  0.472102  0.398456  +0.073645  +18.483%      737.0  427.783   1012     0.2112 0.2182
   2347  00:00:39:07    39.156  0.537254  0.394952  +0.142303  +36.030%     1436.7  439.098   1007     0.3435 0.3516
   2388  00:00:39:48    39.840  0.385155  0.371452  +0.013703   +3.689%      147.1  414.238   1019     0.6616 0.6756
   ...

Vision confidences are measurements, not verdicts. Walk sorts and flags;
the keep/pitch judgment is the operator's or Pixel's.
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

```
make install-mcp     # copies walk-mcp to ~/.local/bin and prints the one command
claude mcp add --scope user --transport stdio walk ~/.local/bin/walk-mcp
```

`make mcp-check` replays both protocol eras against the built binary and
requires the refusals — an unsupported protocol version, an unknown tool, and a
consumer written against an older Walk. Set `WALK_MCP_LOG=<file>` in the
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

## Build

```
swift build -c release        # the library, the CLI and the MCP server
make test                     # 48 tests
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
- **The app is not sandboxed.** The trade is stated in `WalkApp.swift`.
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

**5. Walk sorts and flags. It never renders a keep/pitch verdict.** Session #228
measured that the operator's best-selling photograph fails nearly every
technical metric taken on it — 66.57% shadow, clipped at both ends, the highest
noise floor and the smallest file of the set. A tool that discarded his best
seller because it scored badly would be worse than no tool. Walk reports
measurements and confidences. The judgment stays with the operator, or with
Pixel on the finals.

**6. Every finding declares how it was established.** Measured, inferred, or
reported. The changelog says which, every time.

## License

MIT © lucidIT LLC
