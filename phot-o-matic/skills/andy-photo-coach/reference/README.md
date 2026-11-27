# Andy — origin reference

## `gpt-spec-12.json`

**Andy's ancestor, not a fork.** This skill's changelog records 1.0.0 (2026-03-29) as
*"Initial o-MATIC build from GPT Spec 12"*, and this file's own `version` field
reads `Spec 12 • GPT-5.1` — the same spec number, retagged for a newer model.
It is where this skill started, supplied by the operator 2026-09-12.

Kept for provenance and for one specific reason: **five capabilities specified
here did not survive into the o-MATIC build**, measured 2026-09-12 against
the 2.5.0 skill. Three of them are things the operator asked for again, five months
later, without knowing he had already specified them.

| Spec 12 capability | skill 2.5.0 |
|---|---|
| Darkroom Notes, Over-Edit Alert, Fix-List, Before-You-Upload, stock/series/aesthetic modes, Joy Principle, IPTC, presets | carried |
| `canvas_overlays` — `crop_box`, `mask`, `callout` | **absent** |
| `golden_ratio` guide | **absent** |
| Drills — teaching exercises | **absent** |
| `user_style_profile` | **absent** |
| `accepted_edits` memory, 90-day TTL | **absent** |

Tracked as task #724. Do not treat this file as current authority for anything:
it predates every correction made on 2026-09-11 and 2026-09-12, including the
reversed `magentaGreen` sign (#492, task #719), the calibrate-don't-sweep method
(#491), and §8.5's Walk version contract. It is a source of RECOVERABLE IDEAS,
not of operating instructions.

**On the name.** This spec and every reference inside it say **Pixel**. That is
the name the skill shipped under until decision #538 (2026-09-13) retired it in
favor of **Andy**. The archived JSON is left byte-for-byte as supplied — #421,
retirement is a state and not a delete — so a reader will find the old name
there and should not "correct" it. The live skill is `andy-photo-coach`.
