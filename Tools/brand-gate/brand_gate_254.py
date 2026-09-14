#!/usr/bin/env python3
"""
CONFORMANCE CHECK for the known_rules #254 brand gate over the Walk criteria set
that ships INSIDE the public plugin (decision #534).

Built by Smith as the executable half of Brandy's gate (brand.brand_messaging
id 105), whose own verdict was design_verified: nothing had demonstrated it
could refuse. Moved into this repository and RE-AIMED by Carver 2026-09-13 under
operator ruling #536.

WHAT #536 CHANGED, AND IT CHANGED WHAT COUNTS AS A VIOLATION
------------------------------------------------------------
Brandy's gate required the nine rule `origin` fields rewritten into public prose
with the decision numbers stripped. The operator OVERRULED that, and the
rationale is the part that matters here, verbatim from #536 ruling 1:

    "#499 exists so the operator can audit the advice rather than trust it, and
    the audit trail IS the decision number - it is the thing that resolves to a
    record. ... Three of the nine rules disclose that NO measurement sets their
    threshold, and Brandy's required form - name what was measured, on what,
    when - is UNSATISFIABLE for those three. The path of least resistance for an
    implementer would be to drop the disclosure or invent a measurement."

So two detectors were aimed at the wrong target and are re-aimed:

  N2 previously flagged an internal decision/task/rule/SOP/KB number ANYWHERE,
     including `origin`. Under #536 a decision number in `origin` is CORRECT.
     N2 now SKIPS `origin` and keeps firing everywhere else — the owner string
     and all free prose — because in customer-facing narrative an internal
     number is still an index into a record the customer cannot open.

  N8 previously fired when an origin named neither a measurement nor the absence
     of one. It is INVERTED in the sense #536 requires: the presence of an
     auditable anchor is now what satisfies the rule, and its ABSENCE is the
     defect. A decision number is a first-class anchor rather than a smell.

N8'S ACCEPTED ANCHORS, and why there are three rather than one.
#499 field 4 asks a rule to name what established it. Exactly three answers are
honest, and #536's rationale names all three:
  (a) an internal ruling that resolves to a record — a decision/task/rule number;
  (b) a measurement — a date, or the word measured;
  (c) an explicit disclosure that JUDGMENT and not measurement set the threshold.
Requiring (a) alone would force a decision number onto the craft calls that
genuinely have none, which is inventing provenance. Requiring (b) alone is the
form #536 calls UNSATISFIABLE for three of the nine. Accepting any of the three,
and nothing else, is the only reading under which no rule is pushed to lie.

Exit 0 = PASS. Exit 1 = BLOCK (findings printed). Exit 2 = usage error.
"""
import json, re, sys, os

# Personas that #505 confines, and every o-MATIC roster name that must never
# reach a customer-facing artifact. ANDY is permitted INSIDE Walk only (#505).
FORBIDDEN_PERSONAS = ["Pixel", "Brandy", "Carver", "Monet", "Probot", "Fred",
                      "Smith", "Jake", "Tim", "Jo "]
ALLOWED_PERSONA = "Andy"

# Manufacturer / agency names — decision #503 downstream: "No manufacturer or
# agency name ... appears in any public-facing copy."
AFFILIATION = ["Canon", "Nikon", "Sony", "Fujifilm", "Leica", "Hasselblad",
               "Getty", "Shutterstock", "Alamy", "Adobe Stock", "sponsor",
               "sponsored", "prototype glass", "well published", "on assignment for"]

RE_INTERNAL_REF   = re.compile(r'(decision\s*#\d+|task\s*#\d+|rule\s*#\d+|known_rules|SOP-\d+|KB-\d{4}|#\d{3,4})')
RE_INTERNAL_VER   = re.compile(r'((?:skill|pack|plugin|Studio pack|Agency pack|Firm pack)\s+v?\d+\.\d+\.\d+)', re.I)
RE_SOURCE_SYMBOL  = re.compile(r'([A-Z][A-Za-z0-9]+\.[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+|\b\w+\.swift\b|\bSources/|\b(?=[0-9a-f]{7,40}\b)(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b)')
RE_OUTCOME        = re.compile(r'(you will sell|will sell\b|lose nothing|guarantee[ds]?\b|get you published|make you money|the most [a-z]+ .{0,30}there is)', re.I)

# --- N8's three accepted anchors (see the module docstring) -----------------
# (a) an internal ruling that resolves to a record. #536 ruling 1.
RE_ORIGIN_RULING    = RE_INTERNAL_REF
# (b) a measurement.
RE_ORIGIN_MEASURED  = re.compile(r'\b(20\d\d-\d\d-\d\d|measured|measurement)\b', re.I)
# (c) an explicit disclosure that judgment, not measurement, set the threshold.
#     "craft call" and "own judgment" are here because the live artifact uses
#     both to make exactly this disclosure, and #536 ruling 1 is explicit that
#     the disclosure "must survive the public rewrite" rather than be reworded
#     into a shape the checker happens to recognise.
RE_ORIGIN_DISCLOSED = re.compile(
    r'(no measurement|no record|not measured|no decision record|no threshold was measured'
    r'|set by judgment|craft call|own judgment|judgment\b.{0,40}\bnot\b)', re.I)

# `origin` is the field #536 protects. N2 is the only detector that stands down
# there; N1, N3, N4, N5 and N6 still apply, because #536 preserved the decision
# NUMBERS and said nothing about persona names, pack versions, source symbols,
# affiliations or outcome promises.
N2_EXEMPT_FIELDS = ("origin",)


def findings_for(path, label, text):
    field = label.rsplit(".", 1)[-1]
    out = []
    for p in FORBIDDEN_PERSONAS:
        if re.search(r'\b' + re.escape(p.strip()) + r'\b', text):
            out.append(("N1_PERSONA_FORBIDDEN", label, p.strip(),
                        "#505 confines the coach to Walk; no other roster name ships."))
    if field not in N2_EXEMPT_FIELDS:
        for m in RE_INTERNAL_REF.findall(text):
            out.append(("N2_INTERNAL_REF", label, m,
                        "An internal number in customer-facing prose indexes a record the reader "
                        "cannot open. #536 keeps them in `origin` only, as the audit trail."))
    for m in RE_INTERNAL_VER.findall(text):
        out.append(("N3_INTERNAL_VERSION", label, m, "Internal pack/skill version in customer-facing content."))
    for m in RE_SOURCE_SYMBOL.findall(text):
        out.append(("N4_SOURCE_SYMBOL", label, m, "Source symbol, file path or commit hash in customer-facing prose."))
    for a in AFFILIATION:
        if re.search(r'\b' + re.escape(a) + r'\b', text, re.I):
            out.append(("N5_AFFILIATION", label, a,
                        "#503 downstream / #254: no manufacturer or agency name in public copy."))
    for m in RE_OUTCOME.findall(text):
        out.append(("N6_OUTCOME_PROMISE", label, m if isinstance(m, str) else m[0],
                    "#254 evidence ceiling: a coaching line may not promise a commercial outcome."))
    return out


def check(path, enabled=None):
    enabled = enabled or {"N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8"}
    f = []
    base = os.path.basename(path)
    # N7 — the shipped FILENAME is customer-facing too. A surface Brandy's
    # verdict does not cover at all; task #775.
    for p in FORBIDDEN_PERSONAS:
        if p.strip().lower() in base.lower():
            f.append(("N7_FILENAME_PERSONA", base, p.strip(),
                      "A retired persona name in a shipped filename is public copy."))
    d = json.load(open(path, encoding="utf-8"))
    c = d.get("criteria", {})
    for k in ("owner", "note", "established", "version", "walk"):
        if isinstance(c.get(k), str):
            f += findings_for(path, "criteria." + k, c[k])
    for i, r in enumerate(d.get("rules", [])):
        rid = r.get("id", "rule[%d]" % i)
        for k in ("reason", "origin", "change", "forwardQuestion", "nextFlight"):
            if isinstance(r.get(k), str):
                f += findings_for(path, "%s.%s" % (rid, k), r[k])
        # N8 — #499 field 4 must be PRESENT and must be ANCHORED.
        o = (r.get("origin") or "").strip()
        if not o:
            f.append(("N8_ORIGIN_MISSING", rid, "(empty)",
                      "#499 field 4 is not waived; no rule ships without it."))
        elif not (RE_ORIGIN_RULING.search(o)
                  or RE_ORIGIN_MEASURED.search(o)
                  or RE_ORIGIN_DISCLOSED.search(o)):
            f.append(("N8_ORIGIN_UNANCHORED", rid, o[:60],
                      "Origin names no ruling, no measurement and no disclosure that judgment set "
                      "the threshold. #536: the audit trail is what #499 field 4 is for, and a rule "
                      "that cannot name what established it is unauditable."))
    return [x for x in f if x[0].split("_")[0] in enabled]


# ---------------------------------------------------------------------------
# THE WAIVER FILE, and why a gate that can be waived is still a gate.
#
# Some findings against the live artifact are PROTECTED BY A RULING OR ROUTED TO
# AN OWNER WHO IS NOT THIS REPOSITORY. Carver may not silently fix those, and a
# gate that stays permanently red is a gate everyone learns to ignore — which is
# the failure this control exists to end, arriving by a different door.
#
# So each one is waived EXPLICITLY, BY EXACT (code, location, token) TRIPLE,
# with the authority that permits it written next to it. The consequences:
#   - a NEW violation of any class is still red, because it will not match a
#     triple;
#   - the waived set is a short, readable list rather than a disabled detector;
#   - a waiver that stops matching is itself reported, so a waiver cannot quietly
#     outlive the finding it covers.
# ---------------------------------------------------------------------------
def load_waivers(path):
    if not path or not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip() if not line.strip().startswith("#") else ""
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        out.append(tuple(parts[:3]) + (parts[3],))
    return out


def main(argv):
    if len(argv) < 2:
        print("usage: brand_gate_254.py <criteria.json> [--waivers <file>]")
        return 2
    path = argv[1]
    waiver_path = None
    if "--waivers" in argv:
        waiver_path = argv[argv.index("--waivers") + 1]
    waivers = load_waivers(waiver_path)
    wkeys = {w[:3] for w in waivers}

    fs = check(path)
    seen, blocking, waived = set(), [], []
    for code, loc, tok, why in fs:
        key = (code, loc, tok)
        if key in seen:
            continue
        seen.add(key)
        (waived if key in wkeys else blocking).append((key, why))

    unused = [w for w in waivers if w[:3] not in seen]

    if waived:
        print("WAIVED (%d) — each by a named authority, and still visible:" % len(waived))
        auth = {w[:3]: w[3] for w in waivers}
        for key, _ in waived:
            print("  %-22s %-46s %r" % key)
            print("      authority: %s" % auth[key])
        print("")

    if unused:
        # A waiver covering nothing is stale doctrine in miniature — it asserts a
        # violation exists that does not. Reported, and it fails the gate.
        print("STALE WAIVERS (%d) — these match no current finding and must be removed:" % len(unused))
        for w in unused:
            print("  %-22s %-46s %r" % (w[0], w[1], w[2]))
        print("")

    if not blocking and not unused:
        print("PASS  %s  — no unwaived #254 finding" % path)
        return 0

    if blocking:
        print("BLOCK %s  — %d unwaived finding(s)" % (path, len(blocking)))
        for key, why in blocking:
            print("  %-22s %-46s %r" % key)
            print("      %s" % why)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
