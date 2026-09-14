#!/usr/bin/env python3
"""Retired-PRODUCT-name detector, plus the inverted wire-drift assertion.

WHY THIS EXISTS, and why it is two checks rather than one.

Decision #539 retired WALK to what it always was — the development name — and
#540/#542 set the product to `phot-o-MATIC`. #542 holds the WIRE: six MCP tool
names, WalkKit, the walk and walk-mcp binaries, the criteria engine-version
field, sellableAsShot. A rename that moves those is a breaking schema change.

A one-directional check only punishes UNDER-renaming. The defect this estate has
actually paid for is the other direction: the Pixel-to-Andy pass rewrote
`PixelReaderRGBA16` to `AndyReader*` because an Affinity API identifier looked
like a name (#525, #539 rationale). So there are two halves here and the second
one is the one that matters:

  RETIRED half  — the retired product name must not appear on the PUBLISHED
                  surface, except where a line names it to forbid it, records
                  dated history, carries a wire token, or uses the English verb
                  protected by brand_messaging #73.

  WIRE half     — every held wire token must still be PRESENT at its anchor.
                  This FAILS when an over-enthusiastic rename eats one.

SCOPED ON PURPOSE. A repo-wide grep for `walk` returns ~987 lines of which ~887
are correct. A check that fires 887 false positives is a check somebody disables
in a week. The retired half is scoped to the surface a consumer actually reads —
the same surface `make plugin-check` stages, plus the served MCP strings.

Run:  ./.github/check-product-name.py
      ./.github/check-product-name.py --selftest
      ./.github/check-product-name.py --product phot-o-MATIC   # the inverted run
      ./.github/check-product-name.py --no-allowlist           # population count
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# THE PUBLISHED SURFACE. Globs, relative to the repository root.
#
# Both the pre-layout-fix (plugin at root) and post-layout-fix (plugin in
# ./phot-o-matic/) spellings are listed, so this file does not need editing when
# the pack moves into its subdirectory — decision #106 forbids a repo being both
# marketplace and plugin at root.
# --------------------------------------------------------------------------
SCOPE = [
    ".claude-plugin/marketplace.json",
    ".agents/plugins/marketplace.json",
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "*/.claude-plugin/plugin.json",
    "*/.codex-plugin/plugin.json",
    "*/.mcp.json",
    "README.md",
    "skills/*/SKILL.md",
    "*/skills/*/SKILL.md",
    "Sources/walk-mcp/Server.swift",
    "Sources/walk-mcp/Tools.swift",
    "criteria/*.json",
]

# --------------------------------------------------------------------------
# DEFERRED — in scope, reported, but NOT fatal, because the strings are ruled
# somewhere this check does not outrank.
#
# criteria/walk-criteria.json is a brand-gated artifact. Brandy gated its
# strings on 2026-09-13 (brand.brand_messaging id 105) against a WALK-branded
# file, and task #770 fixed `criteria.owner` as operator-authorized wording —
# Tools/brand-gate/run_eval.py:157 asserts it verbatim, and MEASURED 2026-09-14
# a rename of that one field turned `make gate-check` RED. #542 requires a FRESH
# brand pass over the renamed surface; until that pass runs, this file is
# REPORTED and not rewritten.
#
# A deferred finding is printed every run. It is not silence, and it is not a
# pass either — it names who owns the string and why this check stood down.
# --------------------------------------------------------------------------
DEFERRED = {
    "criteria/": (
        "brand-gated artifact — brand_messaging 105 and task #770 own these strings. "
        "Awaiting Brandy's fresh SOP-006 pass over the phot-o-MATIC surface (#542)."
    ),
}

# Files whose ROLE is to preserve the past or to name a dead thing in order to
# forbid it. Exempt wholesale — this is o-matic-supply's own `isDetector`
# reasoning (verify-pack.mjs), applied to files rather than lines.
ROLE_EXEMPT = (
    "CHANGELOG.md",
    ".github/check-doctrine.py",
    "Tools/brand-gate/fixtures/",
)

# --------------------------------------------------------------------------
# WIRE_ALLOW — tokens that legitimately contain the retired name. Each carries
# its reason. A flagged line is cleared only when EVERY occurrence of the
# retired name on it is covered by one of these.
# --------------------------------------------------------------------------
ALLOWLIST_PATH = os.path.join(ROOT, ".github", "product-name-allowlist.json")

# --------------------------------------------------------------------------
# EXEMPT — line-level. A line may name a dead thing in order to forbid it, or
# record dated history. Mirrors o-matic-supply/scripts/verify-pack.mjs.
# --------------------------------------------------------------------------
EXEMPT_LINE = re.compile(
    r"(?:"
    r"was the development name"
    r"|development name"
    r"|formerly|previously|retired|renamed|deprecated"
    r"|named here to forbid|to forbid it"
    r"|historical|history|preserved under the old name"
    r"|decision\s*#\d+"
    r"|\bWalk \d+\.\d+\.\d+\b"
    r")",
    re.IGNORECASE,
)

# --------------------------------------------------------------------------
# THE WIRE. Anchor file -> {token: minimum count}. The inverted assertion.
# Baselines MEASURED 2026-09-14 on 551979a; they are floors, not equalities, so
# ordinary edits do not trip them but a deletion does.
# --------------------------------------------------------------------------
WIRE_ANCHORS = {
    "Sources/walk-mcp/Tools.swift": {
        "walk_scan": 15,
        "walk_scan_folder": 5,
        "walk_proof_sheet": 3,
        "walk_segments": 3,
        "walk_grade": 3,
        "walk_contract": 3,
        '"walk"': 8,  # the JSON response version key, asserted by mcp-handshake.sh
    },
    "Sources/walk-mcp/Server.swift": {
        '.string("walk")': 1,  # serverInfo.name — protocol identity on initialize
    },
    "Sources/WalkKit/Version.swift": {
        "public enum Walk": 1,  # the PixelReaderRGBA16 trap: an API identifier
    },
    "Sources/WalkKit/Coaching.swift": {
        "sellableAsShot": 4,  # band key held by #527
    },
    "criteria/walk-criteria.json": {
        '"walk"': 1,  # engine-version field
    },
    "Package.swift": {
        "WalkKit": 4,
        '"walk-mcp"': 2,
        '.executable(name: "walk"': 1,
    },
    ".github/mcp-handshake.sh": {
        # MEASURED: the assertion is written with SHELL-ESCAPED quotes,
        # \"walk\":\"$("$BIN" --version)\" at line 47 — so the anchor is the
        # escaped form. A floor of '"walk"' found 0 and the selftest caught it
        # on the first run, which is the selftest doing its job on its own check.
        '\\"walk\\"': 1,  # the CI assertion that the response key has not moved
    },
}


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return out.stdout.split()


def load_allowlist(enabled: bool) -> list[dict]:
    if not enabled:
        return []
    with open(ALLOWLIST_PATH) as fh:
        return json.load(fh)["allow"]


def scoped_files(root: str) -> list[str]:
    seen, files = set(), []
    for pattern in SCOPE:
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            rel = os.path.relpath(path, root)
            if rel in seen or not os.path.isfile(path):
                continue
            if any(rel.startswith(r) or rel == r for r in ROLE_EXEMPT):
                continue
            seen.add(rel)
            files.append(rel)
    return files


def candidate_text(root: str, rel: str) -> list[tuple[int, str]]:
    """The part of a file a CONSUMER reads. Not the whole file."""
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    if rel.endswith(".swift"):
        # String literals only. A /// doc comment is not a customer-facing
        # string; #539's scope is "every customer-facing string".
        out = []
        for i, line in enumerate(lines, 1):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            # QUOTES ARE KEPT. `"walk"` as a JSON response key is wire and the
            # allowlist entry is spelled with its quotes; stripping them first
            # would turn a held token into a bare product reference and flag it.
            quoted = " ".join('"%s"' % m for m in re.findall(r'"([^"]*)"', line))
            # a multi-line Swift `"""` literal has no quotes on its own lines;
            # Server.swift's serverInstructions is exactly that shape.
            if rel.endswith("Server.swift") and not quoted:
                quoted = line
            if quoted:
                out.append((i, quoted))
        return out

    if rel.endswith(".json"):
        # VALUES, not keys. `.mcp.json`'s top-level "walk" is the MCP server key
        # (wire); `"name": "walk"` is the plugin name (display).
        raw = open(os.path.join(root, rel), encoding="utf-8").read()
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            return [(i, l) for i, l in enumerate(lines, 1)]
        vals: list[str] = []

        def walk_json(node):
            if isinstance(node, dict):
                for v in node.values():
                    walk_json(v)
            elif isinstance(node, list):
                for v in node:
                    walk_json(v)
            elif isinstance(node, str):
                vals.append(node)

        walk_json(doc)
        out = []
        for v in vals:
            for i, line in enumerate(lines, 1):
                if v.split("\n")[0][:60] and v.split("\n")[0][:60] in line:
                    out.append((i, v))
                    break
            else:
                out.append((0, v))
        return out

    return list(enumerate(lines, 1))


def scan_retired(root: str, product: str, allow: list[dict]) -> list[tuple[str, int, str]]:
    token = re.compile(r"\b" + re.escape(product) + r"\b", re.IGNORECASE)
    findings = []
    for rel in scoped_files(root):
        for lineno, text in candidate_text(root, rel):
            if not token.search(text):
                continue
            if EXEMPT_LINE.search(text):
                continue
            residue = text
            for entry in allow:
                residue = re.sub(entry["token"], " ", residue, flags=re.IGNORECASE)
            if token.search(residue):
                findings.append((rel, lineno, text.strip()[:140]))
    return findings


def scan_wire(root: str) -> list[str]:
    failures = []
    for rel, tokens in WIRE_ANCHORS.items():
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            failures.append(f"{rel}: MISSING — the anchor for {len(tokens)} wire tokens is gone")
            continue
        body = open(path, encoding="utf-8", errors="replace").read()
        for tok, floor in tokens.items():
            n = body.count(tok)
            if n < floor:
                failures.append(
                    f"{rel}: wire token {tok!r} appears {n}x, floor is {floor}x — "
                    "a held wire token stopped appearing. THIS IS THE RENAME EATING THE WIRE."
                )
    return failures


# --------------------------------------------------------------------------
# SELFTEST. Planted positives AND planted negatives, on fixture trees.
# --------------------------------------------------------------------------
def selftest() -> int:
    allow = load_allowlist(True)
    cases, bad = [], 0

    def fixture(files: dict[str, str]) -> str:
        d = tempfile.mkdtemp(prefix="walk-productname-")
        for rel, body in files.items():
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(body)
        return d

    def case(name, expect_fail, findings):
        nonlocal bad
        got = "fail" if findings else "pass"
        want = "fail" if expect_fail else "pass"
        ok = got == want
        if not ok:
            bad += 1
        cases.append((name, want, got, ok))

    # 1. a display name carrying the retired product MUST fail
    d = fixture({".claude-plugin/plugin.json": json.dumps({"displayName": "Walk"})})
    case("displayName: Walk", True, scan_retired(d, "Walk", allow))

    # 2. the same tree renamed MUST pass
    d = fixture({".claude-plugin/plugin.json": json.dumps({"displayName": "phot-o-MATIC"})})
    case("displayName: phot-o-MATIC", False, scan_retired(d, "Walk", allow))

    # 3. a wire token MUST pass (WIRE_ALLOW)
    d = fixture({"README.md": "Call `walk_scan` on one clip, then `walk_contract`.\n"})
    case("wire tokens walk_scan/walk_contract", False, scan_retired(d, "Walk", allow))

    # 4. a dated history line MUST pass (EXEMPT)
    d = fixture({"README.md": "Walk 0.4.1 served this string, verbatim.\n"})
    case("dated history line", False, scan_retired(d, "Walk", allow))

    # 5. the operator's English verb MUST pass — brand_messaging #73
    d = fixture({"README.md": 'You say "go walk this folder" while talking to the coach.\n'})
    case("English verb: go walk this folder", False, scan_retired(d, "Walk", allow))

    # 6. THE INVERTED HALF. A tree whose wire has been renamed MUST fail.
    d = fixture(
        {
            "Sources/walk-mcp/Tools.swift": 'let t = "photomatic_scan"\n',
            "Sources/walk-mcp/Server.swift": "x\n",
            "Sources/WalkKit/Version.swift": "x\n",
            "Sources/WalkKit/Coaching.swift": "x\n",
            "criteria/walk-criteria.json": "{}\n",
            "Package.swift": "x\n",
            ".github/mcp-handshake.sh": "x\n",
        }
    )
    case("wire renamed to photomatic_* (INVERTED)", True, scan_wire(d))

    # 7. the inverted half MUST pass on this repository as it stands
    case("wire intact on the live tree (INVERTED)", False, scan_wire(ROOT))

    width = max(len(c[0]) for c in cases)
    for name, want, got, ok in cases:
        print(f"  [{'ok' if ok else 'BAD'}] {name:<{width}}  expect {want:<4} got {got}")
    print(f"\n{len(cases)} cases, {bad} wrong. "
          + ("selftest OK — the check is proven able to fail." if not bad
             else "SELFTEST FAILED."))
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--product", default="Walk",
                    help="the retired product name to hunt (default: Walk). "
                         "Pass phot-o-MATIC for the inverted run.")
    ap.add_argument("--no-allowlist", action="store_true",
                    help="run with WIRE_ALLOW empty, to print the whole scoped population")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--wire-only", action="store_true")
    ap.add_argument("--retired-only", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    rc = 0

    if not args.wire_only:
        allow = load_allowlist(not args.no_allowlist)
        all_findings = scan_retired(ROOT, args.product, allow)
        findings, deferred = [], []
        for rel, lineno, text in all_findings:
            for prefix, why in DEFERRED.items():
                if rel.startswith(prefix):
                    deferred.append((rel, lineno, text, why))
                    break
            else:
                findings.append((rel, lineno, text))
        if deferred:
            print(f"DEFERRED — {len(deferred)} line(s) carrying {args.product!r}, reported "
                  "and not fatal:\n")
            for rel, lineno, text, why in deferred:
                print(f"  {rel}:{lineno}: {text}")
            print(f"\n  why: {deferred[0][3]}\n")
        if findings:
            print(f"RETIRED PRODUCT NAME {args.product!r} on the published surface "
                  f"— {len(findings)} line(s):\n")
            for rel, lineno, text in findings:
                print(f"  {rel}:{lineno}: {text}")
            print("\nEach of these is read by a consumer. Rename it, or add the token to")
            print(f"  {os.path.relpath(ALLOWLIST_PATH, ROOT)} with the reason it is wire.")
            rc = 1
        else:
            print(f"retired-name half OK — no bare {args.product!r} on the published surface")

    if not args.retired_only:
        failures = scan_wire(ROOT)
        if failures:
            print("\nWIRE DRIFT — a held token stopped appearing:\n")
            for f in failures:
                print(f"  {f}")
            print("\n#542 holds the wire. A rename that moves these is a breaking schema")
            print("change and was not authorized by a display-surface rename.")
            rc = 1
        else:
            print(f"wire half OK — {sum(len(v) for v in WIRE_ANCHORS.values())} held tokens "
                  f"present at {len(WIRE_ANCHORS)} anchors")

    return rc


if __name__ == "__main__":
    sys.exit(main())
