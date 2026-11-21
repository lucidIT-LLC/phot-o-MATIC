---
name: fcpxml-video
description: Hand off footage into Final Cut Pro with a simple FCPXML, and work video frames on-device with Core Video, Vision, and Core ML. Use when drafting XML for import, triaging a video dump, or when someone assumes the engine already writes FCPXML — it does not.
---

# FCPXML and the on-device video pipeline

**Mac-native, on-device first; cloud only as a flagged exception.** Default
frame inference is Core ML, with Core Video pixel buffers and Vision requests
as the input path. MLX is secondary; say so when you leave the default path.

## What the engine already ships

Call `walk_contract` before relying on this list. Confirm it against the live
build rather than this file.

Present at Walk 0.10.0 and later, and still present in Walk 0.10.3:
`video.read`, `video.write.reencode`, `video.retime`, `video.scan`,
`video.detect`, `video.segment`, `video.trim`, `video.yPlane`,
`video.write.passthrough`, `classify.vision`, `coreml.custom`, folder scan,
proof sheets, DJI SRT telemetry, and coach bands for **clips** when a host
criteria set is installed.

**Absent — do not infer them:**

- `fcpxml.export` — no WalkKit code emits FCPXML. Segments still come out as
  `.mov` files only. Final Cut Pro is a valid handoff *target* and is rejected
  as a control surface.
- `coach.stills` — the engine cannot judge a photograph. Andy does, after
  seeing the frame or the measurements.
- `video.audio` — audio is never read, retimed, or written. Segments come out
  silent.
- `app.drive` — the engine does not drive Final Cut Pro, Motion, or
  Pixelmator Pro.
- `touchup`, and the other entries listed in `Walk.notImplemented`.

phot-o-MATIC triages a dump hands-off (`walk_scan_folder`, `walk_segments`,
the `video.*` capabilities). Andy finishes hands-on with the operator in the
operator's app.

## Core Video — frame handling

Source: https://developer.apple.com/documentation/corevideo

- `CVPixelBuffer` — pixel buffer in main memory (the usual Vision / Core ML
  frame type).
- `CVImageBuffer` / `CVBuffer` — base interfaces.
- `CVPixelBufferPool` — recyclable buffers so a long scan does not allocate
  per frame.
- `CVMetalTexture` / `CVMetalTextureCache` — only if a Metal path is required.

Do not use OpenGL / OpenGL ES on a modern Mac path.

Measured pitfall (see `coreml-vision`): saliency `.heatMap` is a
`PixelBufferObservation`; its `.pixelBuffer` is a `CVReadOnlyPixelBuffer`
that `CVPixelBufferGetWidth` refuses. Prefer `salientObjects` boxes
(normalized, origin bottom-left).

Keep decode and inference on-device. Never upload clips to classify them.

## FCPXML — the write path into Final Cut Pro, hand-authored for now

The format is known. The writer is not in this engine. Measured 2026-09-13
(see `creator-studio`):

- DTDs ship inside Final Cut at
  `Contents/Frameworks/Interchange.framework/Versions/A/Resources/`
  (`FCPXMLv1_0.dtd` through **`FCPXMLv1_14.dtd`**). Validate against the DTD
  on disk, not only Apple's web reference. Apple's published page documents
  1.9 and is client-rendered.
- Keep the first FCPXML simple: one spine, real file paths on the operator's
  Mac, titles, markers.
- The operator imports via File > Import > XML.
- Read an open library only as immutable SQLite (`file:<path>?immutable=1`).
  Never run `make` or `delete` against a live library.
- Final Cut discards some telemetry on ingest (`gpmd` / `.SRT`). Ingest from
  the card if phot-o-MATIC needs the sidecar.

FCPXML does **not** drive MotionVFX, Content Hub, in-app text-to-image,
rotoscoping UI, or the Pixelmator Pro automatic save-back.

Until `fcpxml.export` ships, draft the XML as a file the operator reviews and
imports. Do not claim the engine wrote it.

## App-only Final Cut / Motion / Compressor features (coach, don't script)

From the 27 October 2026 press release: MotionVFX (rotoscoping, tracking,
color grading), Content Hub stock, timeline-to-Pixelmator round-trip,
text-to-image in Final Cut Pro and Motion, added transcription languages,
Motion Displacement and 3D camera tracking, Compressor Cinematic mode encode.
Captions stay Generate Captions / Transcript Search, now with more languages.
Details and hook classes live in `creator-studio`.

Never fabricate footage of real people or events.

## 32 GB Apple silicon

- Prefer the engine's existing video tools over loading a second video model.
- For a custom Core ML model on frames, use a compiled `.mlmodelc` and a
  pixel-buffer pool; do not hold full-resolution 4K frames and a large
  language model in memory together.
- Compressor Immersive Video: Apple recommends 64 GB. Do not promise it on
  32 GB.
