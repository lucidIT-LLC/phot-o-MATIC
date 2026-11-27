# Andy — establishing what is true about a file

Reference file for this skill. SKILL.md is the role guide and says when to read this file.

## Establishing What Is True About a File — provenance first, then the control

Two methods, in this order. The first is cheap and answers *where the file came
from*. The second is expensive and answers *what the image actually looks like*.
Running them in the wrong order costs minutes and can still arrive nowhere.

### 5a. Read the file's own record before you measure a single pixel

**`doc.path` returns the absolute source path and `doc.title` returns the bare
filename.** Everything else you would plausibly reach for is `undefined` on this
build — `url`, `fileName`, `filePath`, `name`, `displayName`. Note also that
`Object.keys(doc)` returns an **empty array**, because the members live on the
prototype; enumerate with
`Object.getOwnPropertyNames(Object.getPrototypeOf(doc))` or you will wrongly
conclude the document object has no properties at all.

With the path you can leave Affinity entirely and interrogate the file directly —
`mdls`, `exiftool`, `sips`. **Camera make and model, the creator/software tag,
and the original capture date are facts the file states about itself.** They are
not inferences from its pixels and they cannot be argued with.

**The measured case, 2026-09-12.** A document reported 6048 × 8064, 48.8 MP, and
the operator asked whether it was genuinely that resolution or an upscale — he
suspected it was "grossly over expanded." A pixel-forensics investigation was
opened: high-frequency energy at the Nyquist limit, edge acutance, noise grain
size, and a synthesized control. Four tests, several minutes in, **no verdict
yet**. Reading `doc.path` and running `mdls` on the file answered it in **one
second**:

```
kMDItemAcquisitionModel    = "iPhone 7 Plus"        # native 4032 x 3024
kMDItemCreator             = "Topaz Photo AI 3.6.2"
kMDItemContentCreationDate = 2017-08-21
```

6048 × 8064 is **exactly 2×** 3024 × 4032. The file stated its own provenance
outright while the instrument was still trying to infer it. Worse, the source was
a 2017 **lossy JPEG**, so the upscaler was interpolating compression artifacts
along with the image — which no amount of pixel statistics would have named.

**The rule.** Andy measurement is the right tool for what an image **looks
like**. File metadata is the right tool for where it **came from**. Reach for
the cheap conclusive one first. A provenance question — is this an upscale, was
this AI-processed, what camera shot it, has this been through a pipeline — is
answered by the file's own record, not by its pixels.

Stock work makes this load-bearing rather than academic: AI-upscaled content is
the category agencies most commonly reject or require disclosed, and a contributor
who submits an interpolated file as a native capture risks the account, not just
the image.

### 5b. The in-frame control — when appearance genuinely is the question

Metadata cannot tell you whether *this* frame's grain is real detail or whether
*this* sky has banding. When the question truly is about appearance, **do not
grade the frame against a textbook expectation. Synthesize a control from the
same content and measure the control with the identical instruments.**

The shape:

1. Take the frame in hand.
2. Produce the control by applying the transformation you are testing for — to
   test for a 2× upscale, box-decimate to the suspected native size and
   bilinearly re-expand to the current size.
3. Measure **the same region** of both, with **the same instrument**, at the
   **same settings**.
4. The frame is *like* the control or it is not. That is a comparison against
   this photograph's own content, not against a general claim about what
   upsampled images do.

**Why this matters and why it is not overcaution.** A textbook threshold —
"interpolated edges have acutance below X" — is a claim about photographs in
general. Foliage, water, cloud and skin each carry radically different native
high-frequency energy, so a general threshold produces confident wrong answers on
real frames. The in-frame control removes the generalization entirely: the only
thing being compared is this content against this content.

**Credit where it is due.** This method was Andy's own instinct on 2026-09-12 —
four tests had run, one of them inconvenient for the hypothesis, and rather than
report a verdict on a disagreeing set he began building exactly this control.
The work was cut short because EXIF answered the provenance question first, but
**the instinct was correct and is preserved here**: when four measurements
disagree, the answer is a better-controlled measurement, not a confident average
of the four.

**Both rules, held together:** §5a says do not build an instrument to infer what
a file will simply tell you. §5b says when no file can tell you, build the
control rather than borrowing a threshold. They are not in tension — one is about
provenance, the other about appearance, and knowing which question is in front of
you is the whole skill.

***
