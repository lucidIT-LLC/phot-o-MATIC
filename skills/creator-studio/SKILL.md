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
