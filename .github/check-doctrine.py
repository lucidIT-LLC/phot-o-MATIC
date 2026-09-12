#!/usr/bin/env python3
"""The `instructions` string an MCP host reads BEFORE it picks a tool must state
decision #513's doctrine, and must not state the doctrine #513 reversed.

WHY THIS CONTROL EXISTS, AND WHY IT IS LATE.

Walk 0.4.1 served this, verbatim, to every consumer on connect:

    "It never renders a keep/pitch verdict - sorting and flagging is Walk's job,
     judgment is yours and the operator's."

Decision #513 reverses that exactly: Walk's output IS a coaching verdict in
three bands. So the one text guaranteed to be read first, ahead of every tool
call, described a product decision that had been overturned. Worse than stale:
a consumer told "never renders a verdict" does not ask for one, so the prose
SUPPRESSED the feature it was describing.

0.5.0 corrected it in SEVEN places - the MCP instructions string, README design
rule 5, `walk scan`'s text output, the `--json` note, `walk_scan`'s tool
description, App/WalkApp/WalkApp.swift and Sources/WalkKit/Classifier.swift.
FIVE OF THOSE NOBODY HAD FOUND. That count is the argument for this file: the
correction was done by hand, by reading, and the only reason it reached seven
instead of one is that somebody went looking. Nothing in CI could have told
them, and nothing could tell the next person either.

Every other prose surface in this repository already has a control - the
README's test count against the suite, its tool block against the live schema,
the deprecation inventory against an allowlist, the tag against Walk.version.
The most-read sentence the project owns had none.

HOW IT AVOIDS BECOMING AN EIGHTH COPY OF THE DOCTRINE.

The asymmetry is deliberate and it is the whole design:

  * The REQUIRED doctrine is DERIVED, never retyped. Band labels come out of
    `Coaching.Band.label` and the forward question out of
    `Coaching.forwardQuestion` - the same constants the code judges with. Rename
    a band and this check demands the served prose follow. A retyped list would
    make this file one more thing to keep in sync, which is the defect.
  * The FORBIDDEN doctrine IS named literally, because that is the correct
    shape: a fix names the retired thing in order to forbid it. The same
    reasoning is in the deprecated-API step of ci.yml.

AND THE TIE THAT MATTERS MOST. Stating the bands is not enough on its own. No
criteria ship (#499), so the verdict does not render, and a string that promised
verdicts with nothing behind it would be the worse of the two errors - #736 says
so in terms. This checks BOTH DIRECTIONS: while `coach.verdict` sits in
notImplemented the instructions must state the absence; when it leaves, they
must stop stating it. Neither half can drift alone.

usage: check-doctrine.py <path to walk-mcp> [<path to walk>]
       check-doctrine.py --selftest
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
COACHING_SWIFT = REPO / "Sources" / "WalkKit" / "Coaching.swift"

# The doctrine #513 RETIRED. Named here to forbid it, dash- and
# whitespace-normalized so a re-wrap or an em-dash swap cannot slip a phrase
# past. Each entry is the shape of the claim, not one exact sentence.
FORBIDDEN = [
    "never renders a keep/pitch verdict",
    "never renders a verdict",
    "renders no keep/pitch",
    "sorting and flagging is walk's job",
    "judgment is yours and the operator's",
    "judgment is the operator's",
    "every frame measured; none judged",
    "walk sorts and flags",
]

# Source surfaces that must not carry the retired doctrine in CODE. Comments are
# exempt: Server.swift, Coaching.swift and ProofSheetView.swift all quote the old
# sentence deliberately, to explain what was overturned. A keyword grep that
# could not tell a comment from a served string would fail on the documentation
# and pass on the defect.
SOURCE_DIRS = ["Sources", "App"]

COMMENT = re.compile(r"^\s*(//|/\*|\*|///)")


def norm(s: str) -> str:
    """Fold dashes and whitespace so phrasing survives a re-wrap."""
    s = s.replace("—", "-").replace("–", "-").replace("’", "'")
    return re.sub(r"\s+", " ", s).strip().lower()


def band_labels() -> list[str]:
    """The canonical band labels, read out of `Coaching.Band.label`.

    DERIVED ON PURPOSE. These are the strings the code bands with; the served
    prose is checked against them rather than against a copy kept here.
    """
    src = COACHING_SWIFT.read_text()
    body = re.search(r"public var label: String \{(.+?)\n        \}", src, re.S)
    if not body:
        raise SystemExit("::error::cannot find Coaching.Band.label - has the band "
                         "type moved? This check derives the labels from it and "
                         "must not be given a hardcoded list instead.")
    labels = re.findall(r'return "([^"]+)"', body.group(1))
    if len(labels) != 3:
        raise SystemExit(f"::error::expected #513's three bands, found {len(labels)}: "
                         f"{labels}. A band was added or removed - the ruling is "
                         f"three bands, so this needs a decision, not a bigger list.")
    return labels


def forward_question() -> str:
    src = COACHING_SWIFT.read_text()
    m = re.search(r'forwardQuestion = "([^"]+)"', src)
    if not m:
        raise SystemExit("::error::cannot find Coaching.forwardQuestion")
    return m.group(1)


def served_instructions(binary: str) -> dict[str, str]:
    """The instructions string as each protocol era actually receives it.

    BOTH ERAS, because Server.swift serves the string from two sites -
    `initialize` (legacy) and `server/discover` (modern) - and a host uses one or
    the other. A check that only read one could pass while half the consumers
    were told the wrong thing.
    """
    eras = {
        "legacy (initialize)": {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                       "clientInfo": {"name": "check-doctrine", "version": "1"}}},
        "modern (server/discover)": {
            "jsonrpc": "2.0", "id": 1, "method": "server/discover",
            "params": {"_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28"}}},
    }
    out = {}
    for era, req in eras.items():
        proc = subprocess.run([binary], input=json.dumps(req) + "\n",
                              capture_output=True, text=True, timeout=60)
        text = None
        for line in proc.stdout.splitlines():
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg.get("result"), dict) and "instructions" in msg["result"]:
                text = msg["result"]["instructions"]
        if text is None:
            raise SystemExit(f"::error::{era} returned no `instructions` string. "
                             f"That is not a passing check - a host reads this "
                             f"before it picks a tool, and an absent string "
                             f"cannot be verified. stderr: {proc.stderr[:400]}")
        out[era] = text
    return out


def verdict_is_declared_absent(walk_binary: str) -> tuple[bool, str]:
    """Whether `coach.verdict` sits in notImplemented, per the shipped binary."""
    proc = subprocess.run([walk_binary, "contract"], capture_output=True,
                          text=True, timeout=60)
    text = proc.stdout
    after = text.split("NOT implemented", 1)
    if len(after) < 2:
        raise SystemExit("::error::`walk contract` printed no notImplemented section")
    absent = re.search(r"^\s+coach\.verdict\s*$", after[1], re.M) is not None
    return absent, text


def check(instructions: dict[str, str], labels: list[str], question: str,
          absent: bool, contract: str) -> list[str]:
    """Every assertion. Returns the failures; empty means the doctrine holds."""
    fails = []

    for era, text in instructions.items():
        n = norm(text)

        # 1. The retired doctrine must be gone from the served string.
        for phrase in FORBIDDEN:
            if norm(phrase) in n:
                fails.append(
                    f"{era}: the served instructions carry doctrine decision #513 "
                    f"reversed - {phrase!r}. Walk's output IS a coaching verdict; "
                    f"a consumer told otherwise will not ask for one.")

        # 2. #513's three bands must be stated, derived from Coaching.Band.
        for label in labels:
            if norm(label) not in n:
                fails.append(
                    f"{era}: band {label!r} is defined in Coaching.Band.label but "
                    f"the served instructions never name it. #513's output is the "
                    f"three bands; a host cannot ask for a band it is not told about.")

        # 3. Band 2's forward question is required, not decoration (#513).
        if norm(question) not in n:
            fails.append(
                f"{era}: the forward question {question!r} - required on band 2 and "
                f"enforced in Verdict's initializer - is not in the served "
                f"instructions. It is the mechanism that keeps a photographer "
                f"moving forward rather than having their work sorted for them.")

        # 4. THE TIE, both directions. Absence stated while, and only while,
        #    there is one.
        states_absence = ("coaching.available" in n) and (
            "false" in n or "not available" in n)
        if absent and not states_absence:
            fails.append(
                f"{era}: `coach.verdict` is in notImplemented - no criteria ship, so "
                f"no verdict renders - but the served instructions do not say so. A "
                f"string promising verdicts with nothing behind it is the worse of "
                f"the two errors (#736). State `coaching.available: false` and why.")
        if not absent and states_absence:
            fails.append(
                f"{era}: `coach.verdict` has LEFT notImplemented, so the verdict now "
                f"renders, but the served instructions still tell every consumer it "
                f"is unavailable. The feature shipped and the front door denies it.")

    # 5. The contract's own reason must name the bands too - it is the other
    #    surface a consumer reads, and it went stale independently once.
    if absent:
        cn = norm(contract)
        for label in labels:
            if norm(label) not in cn:
                fails.append(
                    f"`walk contract` explains coach.verdict's absence without naming "
                    f"band {label!r}. The reason a capability is absent is the only "
                    f"thing a consumer has; it must describe what is missing.")

    # 6. And the retired doctrine must be gone from CODE, not only from the one
    #    string. It was found in seven places, five unnoticed.
    for d in SOURCE_DIRS:
        root = REPO / d
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.swift")):
            for i, line in enumerate(path.read_text().splitlines(), 1):
                if COMMENT.match(line):
                    continue
                ln = norm(line)
                for phrase in FORBIDDEN:
                    if norm(phrase) in ln:
                        rel = path.relative_to(REPO)
                        fails.append(
                            f"{rel}:{i}: retired doctrine in code (not a comment) - "
                            f"{phrase!r}. #513 reversed it.")
    return fails


def selftest() -> int:
    """The check must be able to FAIL. A control that has only ever passed is
    not a control - this repository's own words, in ci.yml, three times.

    Each case feeds the assertions an input that is wrong in exactly one way and
    requires the failure. Every band label is exercised individually, so a check
    that silently stopped looking at band 3 is caught.
    """
    labels = band_labels()
    question = forward_question()
    good = (f"Walk is a COACHING tool. Its output is a verdict in three bands: "
            f"{labels[0]}, {labels[1]} (the one change, then \"{question}\"), "
            f"and {labels[2]}. THE VERDICT IS NOT AVAILABLE IN THIS BUILD: every "
            f"scan returns `coaching.available: false` with the reason.")
    contract = " ".join(labels)

    cases: list[tuple[str, dict, bool, str]] = [
        ("the retired sentence returns verbatim",
         {"e": good + " It never renders a keep/pitch verdict - sorting and "
                      "flagging is Walk's job, judgment is yours and the operator's."},
         True, contract),
        ("the retired sentence returns re-wrapped with an em dash",
         {"e": good + " It never renders a keep/pitch verdict — sorting\nand "
                      "flagging is Walk's job."},
         True, contract),
        ("the old proof-sheet promise returns",
         {"e": good + " Every frame measured; none judged."}, True, contract),
        ("the absence is not stated while the verdict is absent",
         {"e": good.split(" THE VERDICT")[0]}, True, contract),
        ("the absence is still stated after the verdict ships",
         {"e": good}, False, contract),
        ("the forward question is dropped",
         {"e": good.replace(question, "good luck")}, True, contract),
        ("the contract stops naming the bands",
         {"e": good}, True, "no bands here"),
    ] + [
        (f"band {i + 1} ({label!r}) is missing from the served string",
         {"e": good.replace(label, "SOME OTHER BAND")}, True, contract)
        for i, label in enumerate(labels)
    ]

    ok = True
    for name, instructions, absent, contract_text in cases:
        fails = check(instructions, labels, question, absent, contract_text)
        # Case 6 legitimately also trips the band-name assertion when a label is
        # replaced; any failure is a pass here. What matters is that silence is
        # not the answer.
        if fails:
            print(f"  caught: {name}")
        else:
            print(f"  ::error::NOT CAUGHT: {name}")
            ok = False

    # And the happy path must actually pass, or the check is merely a tripwire
    # that fires on everything.
    clean = check({"e": good}, labels, question, True, contract)
    # The source sweep runs against the real tree here; report it separately so a
    # genuine source defect is not mistaken for a broken selftest.
    source_only = [f for f in clean if ".swift:" in f]
    if source_only:
        print("  ::error::the working tree carries retired doctrine in code:")
        for f in source_only:
            print(f"    {f}")
        ok = False
    if [f for f in clean if ".swift:" not in f]:
        print("  ::error::a correct instructions string was rejected:")
        for f in clean:
            if ".swift:" not in f:
                print(f"    {f}")
        ok = False
    else:
        print("  passes on a correct string")

    print("selftest: " + ("every case caught" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mcp = sys.argv[1]
    walk = sys.argv[2] if len(sys.argv) > 2 else str(Path(mcp).parent / "walk")

    labels = band_labels()
    question = forward_question()
    absent, contract = verdict_is_declared_absent(walk)
    instructions = served_instructions(mcp)

    print(f"bands (from Coaching.Band.label): {' / '.join(labels)}")
    print(f"forward question: {question!r}")
    print(f"coach.verdict declared absent: {absent}")
    for era, text in instructions.items():
        print(f"{era}: {len(text)} chars served")

    fails = check(instructions, labels, question, absent, contract)
    if fails:
        for f in fails:
            print(f"::error::{f}")
        print(f"\n{len(fails)} doctrine failure(s)")
        return 1
    print("\nthe served doctrine matches #513, and states the absence it must")
    return 0


if __name__ == "__main__":
    sys.exit(main())
