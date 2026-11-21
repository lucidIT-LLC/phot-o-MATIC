---
name: creator-studio
description: Drive Apple's Creator Studio apps — Final Cut Pro, Pixelmator Pro, Photomator, Photos, Motion, Logic — from a factory. Use before claiming any of them can or cannot be automated, when reading a Final Cut library, generating FCPXML, or scripting an image edit. Carries the measured automation surface of each, because several answers are counterintuitive and two have already cost sessions.
---

# Driving Apple's Creator Studio apps

Measured on one Mac, 2026-09-12 and 2026-09-13. A version bump invalidates any
of it — re-measure rather than trusting this file, which is the same discipline
the dates exist to enforce.

## 1. Find the app before concluding anything about it

These install as **"X Creator Studio.app"** — `Final Cut Pro Creator Studio.app`,
`Pixelmator Pro Creator Studio.app`, `Motion Creator Studio.app`. **Photomator
is NOT renamed** and stays `Photomator.app`.

They are also **not necessarily on the boot volume** — Final Cut and Motion were
found at `/Volumes/<name>/Applications/`.

A check for `/Applications/Final Cut Pro.app` finds nothing and concludes the app
is not installed. That happened, and "Final Cut is not scriptable" was published
before it was caught. `mdfind` does not reliably index external volumes; a direct
`ls` across `/Applications`, `/System/Applications`, `/Volumes/*/Applications`
and `~/Applications` does.

## 2. READ THE DICTIONARY WITH xmllint --xinclude, NEVER WITH sdef(1)

**This is the single highest-value line in this file.** Final Cut's
`ProEditor.sdef` declares **one** command in its own bytes and pulls eleven more
through an `xi:include` of `CocoaStandard.sdef` on line 8.

```
grep -c "<command "  ProEditor.sdef            ->  1     WRONG
sdef /Applications/....app | grep -c command   ->  1     ALSO WRONG
xmllint --xinclude ProEditor.sdef | grep -c    ->  12    CORRECT
```

`sdef(1)` does **not** expand the include — measured 2026-09-13. Reading the raw
file reported "Final Cut has one command," which was then repeated to the
operator months later by a session that trusted the note instead of re-running it.

The twelve: `close count delete duplicate exists get make move open print quit save`.

**But inheriting the standard suite is not implementing it.** Whether Final Cut
wires `make` or `delete` to libraries, events and projects is UNTESTED. Do not
claim a write path from the dictionary alone, and do not find out by running
`make` against the operator's open library.

## 3. The measured surface, app by app

| App | Commands | Notes |
|---|---|---|
| **Pixelmator Pro** | **92** | Real read/write surface. `pick color`, auto corrections, `denoise`, `deband`, `crop`, `export as lut`, `undo`. **NO heal, clone, repair or retouch command** — checked all 92 |
| **Photos** | 18 | Asset **source and sink**. No adjustment property, no filter, no render, no pixel accessor |
| **Final Cut Pro** | 12 (see §2) | Read live: enumerate libraries → events → projects. `items of event` returns the event itself, not the clips |
| **Photomator** | **0** | **No .sdef and no App Intents.** Completely undriveable by AppleScript — and see the `coreml-vision` skill, because its engine is 13 CoreML models on disk |

`pick color` in Pixelmator returns **16-bit** (0–65535) while its own dictionary
declares 8-bit. Divide by 257. Probe the range; never infer it.

AppleScript gotchas that cost compiles: `it` is a reserved word — name the loop
variable something else. Nested `repeat with x in <collection> of y` breaks the
reference chain; use explicit indices (`event j of library i`).

## 4. The library at rest

A `.fcpbundle` is a package directory. `CurrentVersion.flexolibrary` and
`<event>/CurrentVersion.fcpevent` are **SQLite 3 Core Data** stores. Media sits
in `<event>/Original Media/` as ordinary files.

Read an OPEN library **read-only** — `sqlite3 "file:<path>?immutable=1"`. It
holds work that is not yours.

`ZNAME` in `ZCOLLECTION` is Core Data *relationship* names, not clip names. To
confirm an import landed, `strings` the `.fcpevent` for the filename.

**Final Cut discards telemetry on ingest.** Measured: a `.mov` inside the library
carries no `gpmd` stream where the card original has one, and the bundle holds
zero `.SRT` sidecars. Ingest from the card, or the measurement layer is gone
before anything can read it.

## 5. FCPXML is the write path

The DTDs ship inside the app at
`Contents/Frameworks/Interchange.framework/Versions/A/Resources/` —
`FCPXMLv1_0.dtd` through **`FCPXMLv1_14.dtd`**. Apple's published reference
documents **1.9**. Validate against the DTD on disk, not the web page.

Apple's developer docs are client-rendered; fetching the URL returns a shell that
reads like an auth wall and is not one. The JSON is at
`https://developer.apple.com/tutorials/data/documentation/<path>.json`. No login.

## 6. Measure size with stat, never du

`du -k` reports DISK USAGE and APFS compresses these files. `PixelmatorPro.sdef`
is **210,164 bytes**; `du` said 28 KB. Use `stat -f %z`. One figure was right by
coincidence, which is indistinguishable from right by method until someone checks.

## 7. November 2026 Creator Studio AI update — re-measure, then trust

Apple announced new Creator Studio AI features on 27 October 2026, shipped as a
free App Store update for existing subscribers in November:

https://www.apple.com/newsroom/2026/10/apple-creator-studio-adds-powerful-new-ai-features-and-even-more-creative-tools/

The tables in §3 were measured 2026-09-12 and 2026-09-13, **before** that
update. They still stand for the commands that were counted. They do **not**
cover Generate Fill, Super Resolution, new MCP surfaces, or anything else the
press release added. Re-measure the dictionaries on the operator's Mac after
the November apps are installed. Do not treat a September measurement as
current for a new feature.

**On-device first; cloud only as a flagged exception.** Prefer work that stays
on the Mac. If a step uploads a file to a network service — including Apple's
Creator Studio Document Exporting API — stop, label it a **cloud exception**,
quote the privacy notice the API requires, and wait for an explicit opt-in.

### Hook classes

- **Agent hook** — a documented API, file format, MCP server, or a measured
  automation dictionary. An agent may drive it.
- **App-only** — the feature lives in Apple's UI. Coach the operator inside the
  app. Do not invent a script for it.
- **Unverified** — announced or plausible, not measured on the updated app.

Never invent MCP tool names, AppleScript commands, or Core ML input shapes.
Discover live tools on the Mac; do not assume a press-release name is a hook.

### Feature map (from the 27 October 2026 press release)

| Feature | Hook class | How to use it |
|---|---|---|
| Keynote, Pages, Numbers MCP (macOS 27+) | Agent hook (announced; tool surface not yet in developer docs) | Discover live tools on the Mac |
| Keynote Interchange Format (`.keyx`) | Agent hook | Read and write the local JSON bundle |
| Document Exporting API (Pages/Numbers/Keynote → PDF; `.key` ↔ `.keyx`) | Agent hook, **cloud exception** | Opt-in and privacy notice required; files are temporarily stored on Apple servers |
| Pixelmator Pro AppleScript dictionary (92 commands measured 2026-09-13; no heal/clone/repair/retouch) | Agent hook (pre-update) | Re-measure with `xmllint --xinclude` after the November update |
| Pixelmator Pro Generate Fill, Super Resolution, masked new layer | **Unverified**; treat as **app-only** until the updated sdef is measured | Coach the selection and the prompt; the operator clicks; then re-measure |
| Final Cut Pro ↔ Pixelmator Pro automatic round-trip | App-only | Coach inside Final Cut Pro. A file-based stills path is not the same as automatic save-back |
| FCPXML interchange | Agent hook | Validate against the DTD shipped in the app (up to v1.14 measured). phot-o-MATIC does **not** ship `fcpxml.export` — see the `fcpxml-video` skill |
| MotionVFX templates, titles, transitions, rotoscoping, tracking, color grading | App-only | Coach inside Final Cut Pro |
| Content Hub stock video and photos | App-only | Do not scrape or redistribute stock |
| Text-to-image inside Final Cut Pro and Motion | App-only | Coach inside the app. Never fabricate footage of real people or events |
| Final Cut Pro: added transcription languages, keyframe easing, disconnect from storyline | App-only | Coach; no new caption API was measured |
| Motion: MotionVFX plug-ins, 3D camera tracking, Displacement, image generate/edit | App-only | Coach inside Motion |
| Compressor: Cinematic mode encode | App-only | Do not promise Immersive pipelines on a 32 GB Mac; Apple recommends 64 GB |
| Logic Pro assistant, Stem Splitter, Splice, Voice Memo Studio Sound | Mostly app-only; no Logic MCP announced | Out of this pack's lane unless the operator asks |
| Keynote/Pages/Numbers in-app assistants (beta) | App-only (separate from MCP) | Use MCP or `.keyx`; do not impersonate the assistant |
| Freeform: Pixelmator edits, text-to-shapes (December) | App-only, future | Re-measure in December |

## 8. Pixelmator Pro — the photo finishing app

Pixelmator Pro is the designated stills app for finishing a photograph. The
measured 92-command dictionary in §3 is the scripted surface until a
re-measurement says otherwise.

**Generate Fill and Super Resolution are unverified as agent hooks.** The press
release describes selecting an area (Free, Quick, or Magnetic Selection) and
describing a change in natural language, with Super Resolution upscaling
generated content onto a layer or a new masked layer. Do not claim these are
AppleScript- or Shortcuts-driveable until the updated dictionary is measured.

Re-measure checklist (read-only, after the November update):

1. Locate the app — it may be installed as `Pixelmator Pro Creator Studio.app`,
   not necessarily at `/Applications/Pixelmator Pro.app`, and not necessarily
   on the boot volume. Search `/Applications`, `/System/Applications`,
   `/Volumes/*/Applications`, and `~/Applications`.
2. Read the dictionary with `xmllint --xinclude`, never `sdef(1)` alone.
3. Search for generate, fill, super resolution, upscale, prompt, and mask
   commands. Report present or absent.
4. Never run a destructive command against an open customer file to find out.

A file-based alternative to the in-app Final Cut round-trip (operator approval
required): export a still, edit via a measured AppleScript command, write a new
file, import or relink. Say clearly it is not Apple's automatic save-back.

Scripted auto-corrections are not a substitute for a second measurement. One
probe, one solved value, then re-measure. Do not stack unmeasured Generate Fill
passes.

Pixelmator Pro plus Generate Fill plus Super Resolution plus Final Cut Pro can
be heavy on a 32 GB Apple silicon Mac. Close unused apps, and do not also load
a large Core ML or MLX model in the same session unless it has been measured
to fit.

## 9. Default workflows (on-device)

**Still.** Ask the destination (print, web, stock, client, or a Keynote / Final
Cut use). Look at the image, or measure it — do not grade from a path or a
description alone. Prefer phot-o-MATIC for measurement (`walk_scan`,
`walk_grade`, proof sheets). The engine cannot judge a photograph; Andy does
(`coach.stills` is listed in `Walk.notImplemented` — confirm with
`walk_contract`). Finish in Pixelmator Pro; coach Generate Fill in the UI until
scriptability is measured.

**Video.** phot-o-MATIC triages the dump (`walk_scan_folder`, `walk_segments`,
and the `video.*` contract capabilities). Use Core Video pixel buffers with
Vision / Core ML for frame-level work — see `coreml-vision` and `fcpxml-video`.
Write a simple FCPXML for import only as a hand-authored file until
`fcpxml.export` ships; do not drive MotionVFX, Content Hub, or in-app
generators by script. Captions: coach Generate Captions / Transcript Search
inside Final Cut Pro.

## 10. What an assistant can produce without driving the GUI

Scripts, shot lists, caption text, title and lower-third copy, a style sheet
for Motion templates, a simple FCPXML for the operator to import via File >
Import > XML, and stills or graphics files for import. Any command run on the
operator's Mac needs their approval; never move or delete their media.
