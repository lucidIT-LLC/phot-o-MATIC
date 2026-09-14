#!/usr/bin/env python3
"""Conformance runner: SHIP THE CHECK, THEN PROVE IT CAN FAIL.

Smith's original runner, moved into this repository and extended by Carver
2026-09-13 for operator ruling #536. Three changes, each because something was
measured wrong rather than because it looked untidy:

 1. THE GREEN BASELINE WAS NOT GREEN. The runner used P1-clean-remediated.json
    as its zero-findings case and that fixture trips N6 three times, so the whole
    suite reported RED (1) on a clean tree and had done since it was written. A
    baseline that fails is a suite whose red light means nothing. P2, whose own
    docstring in task #773 records that it "returns zero findings", is the
    baseline; P1 is kept and asserted for exactly the three N6 hits it carries,
    so it still earns its place as the near-clean case.

 2. PART 3 IS NEW and it exists because a re-aim is the easiest thing in this
    file to get backwards. It asserts BOTH halves of #536 directly: an internal
    reference in `origin` must NOT be flagged, and the same reference in prose
    MUST be. A detector re-aimed in one direction only would pass every other
    part of this suite.

 3. Part 4 reads the live artifact through the waiver file, so what it prints is
    what CI will actually do rather than a different, friendlier number.
"""
import sys, os, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("g", os.path.join(HERE, "brand_gate_254.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
F = os.path.join(HERE, "fixtures")
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

NEGATIVES = [
    ("N1-persona-forbidden.json", "N1"),
    ("N2-internal-decision-number.json", "N2"),
    ("N3-internal-pack-version.json", "N3"),
    ("N4-source-symbol-and-commit.json", "N4"),
    ("N5-manufacturer-and-agency.json", "N5"),
    ("N6-outcome-promise.json", "N6"),
    ("N7-pixel-criteria.json", "N7"),
    ("N8a-origin-vacuous.json", "N8"),
    ("N8b-origin-missing.json", "N8"),
]

fail = 0

print("=== PART 1: the baseline is actually green, and each negative is refused ===")
fs = g.check(os.path.join(F, "P2-clean-n6-corrected.json"))
ok = not fs
print(("  PASS-ok " if ok else "  FAIL    ") + "P2-clean-n6-corrected.json (green baseline)"
      + ("" if ok else "  unexpected: %s" % sorted({x[0] for x in fs})))
fail += 0 if ok else 1

# The near-clean case, pinned to the three findings task #773 routed to Brandy.
fs = g.check(os.path.join(F, "P1-clean-remediated.json"))
codes = sorted({x[0] for x in fs})
ok = codes == ["N6_OUTCOME_PROMISE"] and len(fs) == 3
print(("  PASS-ok " if ok else "  FAIL    ") + "P1-clean-remediated.json (near-clean: exactly 3 x N6)"
      + ("" if ok else "  got %d %s" % (len(fs), codes)))
fail += 0 if ok else 1

for fn, expect in NEGATIVES:
    fs = g.check(os.path.join(F, fn))
    codes = {x[0].split("_")[0] for x in fs}
    ok = expect in codes
    print(("  REFUSED " if ok else "  MISSED  ") + "%-36s expected %s, got %s"
          % (fn, expect, sorted(codes)))
    fail += 0 if ok else 1

print("\n=== PART 2: MUTATION — disable each detector, its own negative case must go green ===")
for fn, expect in NEGATIVES:
    off = {"N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8"} - {expect}
    fs = g.check(os.path.join(F, fn), enabled=off)
    load_bearing = not any(x[0].split("_")[0] == expect for x in fs)
    print(("  LOAD-BEARING " if load_bearing else "  NOT-PROVEN  ")
          + "%-36s detector %s" % (fn, expect))
    fail += 0 if load_bearing else 1

print("\n=== PART 3: the #536 re-aim, asserted in BOTH directions ===")
fs = g.check(os.path.join(F, "N2-internal-decision-number.json"))
n2 = [x for x in fs if x[0] == "N2_INTERNAL_REF"]
in_origin = [x for x in n2 if x[1].endswith(".origin")]
in_prose = [x for x in n2 if not x[1].endswith(".origin")]
ok = not in_origin
print(("  OK   " if ok else "  WRONG") + "  N2 stands down in `origin` (#536: the decision number IS the audit trail)"
      + ("" if ok else "  still flagged: %s" % [x[1] for x in in_origin]))
fail += 0 if ok else 1
ok = bool(in_prose)
print(("  OK   " if ok else "  WRONG") + "  N2 still fires in free prose"
      + ("" if ok else "  — the re-aim disabled the detector instead of narrowing it"))
fail += 0 if ok else 1

# N8 INVERTED: a decision number is now a SATISFYING anchor, not a smell.
import json, tempfile
def n8_on(origin):
    d = json.load(open(os.path.join(F, "P2-clean-n6-corrected.json"), encoding="utf-8"))
    d["rules"] = [dict(d["rules"][0], origin=origin)]
    p = os.path.join(tempfile.mkdtemp(), "walk-criteria.json")
    json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
    return {x[0] for x in g.check(p) if x[0].startswith("N8")}

cases = [
    ("decision #504, correcting #495", False, "a ruling that resolves to a record"),
    ("Measured on storm footage, 2026-09-12.", False, "a measurement"),
    ("The coach's own judgment — no measurement sets this threshold.", False, "a no-measurement disclosure"),
    ("Because it seemed about right.", True, "no anchor at all"),
    ("", True, "an empty origin"),
]
for origin, want_finding, label in cases:
    got = n8_on(origin)
    ok = bool(got) == want_finding
    verb = "flags" if want_finding else "accepts"
    print(("  OK   " if ok else "  WRONG") + "  N8 %s %s" % (verb, label)
          + ("" if ok else "  — got %s" % (sorted(got) or "nothing")))
    fail += 0 if ok else 1

print("\n=== PART 4: what task #770 changed, and what ruling #536 forbade changing ===")
live = os.path.join(REPO, "criteria", "walk-criteria.json")
# THE ORIGIN FIELDS ARE ASSERTED, NOT TRUSTED. #536 ruling 1 keeps them as
# written, and "I did not edit them" is exactly the kind of claim this whole
# repository refuses to take on a promise. The nine origins are pinned by hash,
# so any future edit to one fails here and has to be argued for.
ORIGINS_SHA256 = "2b87e500a7e51d3aecf9886b06f1135529e157b13fecf8602af1299cb3a909a9"
if os.path.exists(live):
    import hashlib
    d = json.load(open(live, encoding="utf-8"))
    c = d.get("criteria", {})

    ok = "note" not in c
    print(("  OK   " if ok else "  WRONG") + "  criteria.note is out of the shipped artifact (#770)")
    fail += 0 if ok else 1

    want = "Andy — Walk's photography coach. The judgment in these rules is his."
    ok = c.get("owner") == want
    print(("  OK   " if ok else "  WRONG") + "  criteria.owner is the operator-authorized wording (#770)"
          + ("" if ok else "\n         got: %r" % c.get("owner")))
    fail += 0 if ok else 1

    joined = "\n".join((r.get("origin") or "") for r in d.get("rules", []))
    got = hashlib.sha256(joined.encode("utf-8")).hexdigest()
    ok = got == ORIGINS_SHA256
    print(("  OK   " if ok else "  WRONG")
          + "  the nine `origin` fields are unchanged (#536 ruling 1 cancelled the rewrite)"
          + ("" if ok else "\n         pinned %s\n         actual %s\n"
                           "         If this edit is intended, it needs a ruling that reconciles\n"
                           "         #505 with #536 — see PROPOSED-origin-minimal-edit.md — and then\n"
                           "         this pin is updated deliberately, in the same commit."
                           % (ORIGINS_SHA256, got)))
    fail += 0 if ok else 1

print("\n=== PART 5: the LIVE shipped artifact, through the waiver file, exactly as CI runs it ===")
waivers = os.path.join(HERE, "waivers.txt")
if not os.path.exists(live):
    print("  FAIL    %s does not exist — the criteria path moved and this runner was not told" % live)
    fail += 1
else:
    rc = g.main(["brand_gate_254.py", live, "--waivers", waivers])
    print("  gate exit status: %d" % rc)

print("\nRESULT:", "GREEN — the check is proven able to fail" if fail == 0 else "RED (%d)" % fail)
sys.exit(1 if fail else 0)
