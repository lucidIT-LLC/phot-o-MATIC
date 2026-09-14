# PROPOSED minimal edit to the nine `origin` fields — NEEDS AN OPERATOR RULING

Carver did NOT apply this. It is written out so a ruling costs one word and not
another session's work.

## The contradiction, stated plainly

**Decision #536 ruling 1** keeps the `origin` fields as written so the audit
trail survives, and its rationale is explicitly about decision NUMBERS: *"the
audit trail IS the decision number - it is the thing that resolves to a record."*
The instruction carrying #536 to this session was: do not rewrite the nine
origin fields; if you find yourself editing an origin field, stop.

**Decision #505** confines the coach to Walk and retires the name *Pixel* from
customer-facing surfaces. **Task #775** exists because that name in a shipped
FILENAME is public copy. This artifact ships into the same public marketplace
repository, and the name is in the file CONTENT six times.

#536 does not mention persona names or pack versions. Reading it as protecting
them too is available, but it is not what it argues — and that reading is the
one that would have turned this build green, which is why it was not adopted.

## What this change does and does not touch

- Every decision number, task number and measured figure: **UNCHANGED.**
- `Pixel` -> `Andy` (the name #502 renamed the coach to, permitted inside Walk by #505).
- The internal pack version `skill 2.5.0` / `Pixel 2.5.0` -> dropped, or rendered
  as `the coach's judgment`, which is what it means to a reader who cannot open it.
- Nothing else. Nine one-line edits.

After applying, the #254 gate returns ZERO unwaived findings.

## The nine lines

### `thin-distant-bolt-clean-sky`

BEFORE:
```
decision #504 ("it has the SHAPE of lightning without the BRIGHTNESS of it"); the upper bound on rise is Pixel's own judgment, skill 2.5.0 — no decision record sets it
```
AFTER:
```
decision #504 ("it has the SHAPE of lightning without the BRIGHTNESS of it"); the upper bound on rise is the coach's own judgment — no decision record sets it
```

### `storm-structure-worth-selling`

BEFORE:
```
decision #495 established the built-in Vision taxonomy Walk queries (lightning, thunderstorm, storm — Classifier.stormIdentifiers); the thresholds and the craft call are Pixel's, skill 2.5.0
```
AFTER:
```
decision #495 established the built-in Vision taxonomy Walk queries (lightning, thunderstorm, storm — Classifier.stormIdentifiers); the thresholds and the craft call are the coach's
```

### `bolt-core-on-the-ceiling`

BEFORE:
```
Walk 0.5.0 exposes yMax as a 10-bit code value with a 1023 ceiling (ClipScan.Candidate); the guard sits at 1020 rather than 1023 because Walk's default triage path sub-samples the Y plane at stride 4 and a sampled maximum can miss the true peak — the general rule below catches that case. Craft call: Pixel 2.5.0 §9.9, §9.13.
```
AFTER:
```
Walk 0.5.0 exposes yMax as a 10-bit code value with a 1023 ceiling (ClipScan.Candidate); the guard sits at 1020 rather than 1023 because Walk's default triage path sub-samples the Y plane at stride 4 and a sampled maximum can miss the true peak — the general rule below catches that case. Craft call: the coach's judgment (sections 9.9 and 9.13. of his own craft notes)
```

### `bolt-the-classifier-half-recognizes`

BEFORE:
```
Pixel 2.5.0, the coach's own judgment — no decision record sets a mid-confidence threshold. The measured anchors either side are decision #495 (frame 2347 at 0.3435 is a confirmed strike; frame 2348 at 0.0129 is not, a 27x separation) and decision #504.
```
AFTER:
```
the coach's own judgment — no decision record sets a mid-confidence threshold. The measured anchors either side are decision #495 (frame 2347 at 0.3435 is a confirmed strike; frame 2348 at 0.0129 is not, a 27x separation) and decision #504.
```

### `storm-structure-flat-light`

BEFORE:
```
decision #495 (the thunderstorm identifier Walk queries); decision #496 places the finishing move in Pixel's app-side lane rather than in the engine. Threshold and craft call: Pixel 2.5.0.
```
AFTER:
```
decision #495 (the thunderstorm identifier Walk queries); decision #496 places the finishing move in the coach's app-side lane rather than in the engine. Threshold and craft call: the coach's judgment.
```

### `nothing-the-classifier-recognizes`

BEFORE:
```
decision #513 requires the band to say why plainly so the tell is learned; decision #499 requires a judgment to name its origin — this threshold is Pixel's, skill 2.5.0, and no decision record sets it
```
AFTER:
```
decision #513 requires the band to say why plainly so the tell is learned; decision #499 requires a judgment to name its origin — this threshold is the coach's, and no decision record sets it
```


---

6 of 9 origins change. The other 3 contain neither a persona name nor a pack version and are untouched.
