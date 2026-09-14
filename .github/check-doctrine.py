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

WHAT THIS CHECK MISSED, AND MANDATED - ADDED 2026-09-13, TASK #736.

The 0.5.0 string served "THE VERDICT IS NOT AVAILABLE IN THIS BUILD AND EVERY
RESULT SAYS SO... Walk ships none, so each scan returns `coaching.available:
false`". MEASURED on a host with Pixel's set installed: `walk_contract` reports
`coach.available: true`, criteria 1.2.0, 9 rules. The front door was telling
every consumer its coaching was dark at the moment it was lit - the 0.4.1 defect
with its sign reversed, and with the same consequence, since a consumer told the
verdict is unavailable does not ask for one.

THIS CHECK PASSED ON IT, AND COULD NOT HAVE DONE OTHERWISE. Assertion 4 ties the
served absence to `coach.verdict` being in notImplemented, which is BUILD state -
do criteria SHIP inside Walk - and satisfied itself with the tokens
"coaching.available" and "false" appearing anywhere. Whether a verdict RENDERS is
HOST state, decided by whether a set is installed at
~/Library/Application Support/Walk/criteria.json or named in WALK_CRITERIA. Build
state cannot settle host state, so the check was structurally blind to the
defect - AND WORSE, IT REQUIRED THE SENTENCE THAT CARRIED IT. A control that
mandates the defect is not a weak control; it is the wrong control, and that is
the finding worth more than the fix.

Assertion 4b is the repair: while the absence is stated it must be stated
CONDITIONALLY and the host mechanism must be named, with the env key DERIVED from
`Criteria.environmentKey` rather than retyped, and the universal forms named
literally in FORBIDDEN alongside the doctrine #513 retired. The asymmetry is the
same one the rest of this file uses.

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
    # #736, 2026-09-13: the same suppression with its sign reversed. These are
    # UNIVERSAL claims about host state, and a host with a criteria set installed
    # makes each of them false while the build is unchanged.
    "the verdict is not available in this build and every result says so",
    "every result says so",
    "walk ships none, so each scan returns",
    "each scan returns `coaching.available: false`",
    "every scan returns `coaching.available: false`",
    "every scan reports `coaching.available = false`",
]

# The word that makes the absence a CONDITION rather than a universal. One of
# these must appear near the absence claim; they are ordinary English, not a
# doctrine copy, which is why naming them here is not an eighth copy.
CONDITIONAL_MARKERS = ["only where", "only when", "unless", "until a criteria set is installed",
                       "where no matching criteria set", "if no criteria set"]

CRITERIA_SWIFT = REPO / "Sources" / "WalkKit" / "Criteria.swift"

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


def criteria_environment_key() -> str:
    """`Criteria.environmentKey`, DERIVED. The served string must name the host
    mechanism, and if that key is ever renamed this check demands the prose follow
    rather than going quietly stale - which is the whole failure being repaired."""
    m = re.search(r'environmentKey = "([^"]+)"', CRITERIA_SWIFT.read_text())
    if not m:
        raise SystemExit("::error::cannot find Criteria.environmentKey - the host "
                         "mechanism this check names must be derived, not retyped.")
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
          absent: bool, contract: str, env_key: str = "WALK_CRITERIA") -> list[str]:
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
        # 4b. THE ABSENCE MUST BE STATED AS HOST STATE, NOT AS A UNIVERSAL.
        #     Criteria not SHIPPING is build state; a verdict not RENDERING is
        #     host state, and a host with a set installed at the default location
        #     or named in the env key renders one. See the header.
        if absent and states_absence:
            if not any(m in n for m in CONDITIONAL_MARKERS):
                fails.append(
                    f"{era}: the served instructions state `coaching.available: "
                    f"false` without a condition. No criteria SHIPPING is build "
                    f"state; no verdict RENDERING is host state, and a host with a "
                    f"criteria set installed renders one. Say when it is false, not "
                    f"that it always is.")
            if norm(env_key) not in n:
                fails.append(
                    f"{era}: the served instructions describe the verdict as "
                    f"unavailable without naming {env_key} - the mechanism that "
                    f"makes it available. A consumer told a feature is absent, and "
                    f"not told how it arrives, reads the absence as permanent.")
            if "walk_contract" not in n:
                fails.append(
                    f"{era}: the served instructions answer the availability "
                    f"question themselves instead of sending the consumer to "
                    f"walk_contract, which MEASURES it on this host. This string is "
                    f"baked into the binary; availability is not.")

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
    env_key = criteria_environment_key()
    good = (f"Walk is a COACHING tool. Its output is a verdict in three bands: "
            f"{labels[0]}, {labels[1]} (the one change, then \"{question}\"), "
            f"and {labels[2]}. NO CRITERIA SHIP INSIDE WALK, so a scan returns "
            f"`coaching.available: false` ONLY WHERE no matching criteria set is "
            f"installed. Call walk_contract to read it on this host; a set is "
            f"named in {env_key}.")
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
         {"e": good.split(" NO CRITERIA SHIP")[0]}, True, contract),
        ("the absence is still stated after the verdict ships",
         {"e": good}, False, contract),
        ("the forward question is dropped",
         {"e": good.replace(question, "good luck")}, True, contract),
        ("the contract stops naming the bands",
         {"e": good}, True, "no bands here"),
        # 4b - the #736 defect itself, in each of the three ways it can be made.
        ("the absence is stated as a universal instead of a condition",
         {"e": good.replace("ONLY WHERE no matching criteria set is installed",
                            "and every result says so")}, True, contract),
        ("the absence is unconditional without the retired wording",
         {"e": good.replace("ONLY WHERE", "always, and")}, True, contract),
        (f"the absence is stated without naming {env_key}",
         {"e": good.replace(env_key, "some other place")}, True, contract),
        ("the string answers availability instead of sending them to walk_contract",
         {"e": good.replace("walk_contract", "this text")}, True, contract),
    ] + [
        (f"band {i + 1} ({label!r}) is missing from the served string",
         {"e": good.replace(label, "SOME OTHER BAND")}, True, contract)
        for i, label in enumerate(labels)
    ]

    ok = True
    for name, instructions, absent, contract_text in cases:
        fails = check(instructions, labels, question, absent, contract_text, env_key)
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
    clean = check({"e": good}, labels, question, True, contract, env_key)
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
    env_key = criteria_environment_key()
    absent, contract = verdict_is_declared_absent(walk)
    instructions = served_instructions(mcp)

    print(f"bands (from Coaching.Band.label): {' / '.join(labels)}")
    print(f"forward question: {question!r}")
    print(f"coach.verdict declared absent: {absent}")
    print(f"host mechanism (from Criteria.environmentKey): {env_key}")
    for era, text in instructions.items():
        print(f"{era}: {len(text)} chars served")

    fails = check(instructions, labels, question, absent, contract, env_key)
    if fails:
        for f in fails:
            print(f"::error::{f}")
        print(f"\n{len(fails)} doctrine failure(s)")
        return 1
    print("\nthe served doctrine matches #513, and states the absence it must")
    return 0


if __name__ == "__main__":
    sys.exit(main())
