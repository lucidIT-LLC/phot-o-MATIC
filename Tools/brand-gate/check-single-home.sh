#!/bin/bash
# ONE HOME FOR THE #254 GATE, ENFORCED RATHER THAN REQUESTED.
#
# WHY THIS FILE EXISTS. MEASURED 2026-09-13: the conformance check existed in
# two places and had already diverged.
#
#   Tools/brand-gate/                                   (this repo, the real one)
#   ~/Documents/Work/O-Matic/artifacts/walk/brand-gate-eval/   (the stale twin)
#
# The twin still carried the pre-#536 detectors, was missing BOTH fixes made to
# the suite itself, and pointed at criteria/pixel-criteria.json — a path renamed
# out of existence by #775. It raised FileNotFoundError, printed a traceback,
# AND EXITED 0. A control that crashes and reports success, inside the check
# built to catch exactly that.
#
# Two copies of a control is the same defect class as prose describing a
# mechanism that no longer exists: nothing can notice the drift. A README saying
# "keep these in sync" is that same defect wearing a instruction. This is the
# mechanical version.
#
# WHAT IT CHECKS, AND WHERE EACH CHECK IS MEANINGFUL:
#
#  1. IN-REPO, and this runs everywhere including CI. There must be exactly one
#     brand_gate_254.py and one run_eval.py in this repository. A second copy
#     anywhere in the tree fails.
#
#  2. ON THE ESTATE, and this only runs where the estate exists. If the retired
#     O-Matic path is present it must contain NO executable check — only the
#     refusing stub. On a CI runner that path does not exist, and the script
#     SAYS SO rather than passing silently: a check that is vacuous where it
#     runs must not report the same word as a check that passed.
#
# usage: check-single-home.sh [--selftest]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RETIRED="${WALK_RETIRED_GATE_PATH:-$HOME/Documents/Work/O-Matic/artifacts/walk/brand-gate-eval}"

check() {
	local repo="$1" retired="$2" failures=0

	# --- 1. in-repo uniqueness -------------------------------------------
	local n_gate n_runner
	n_gate=$(find "$repo" -name 'brand_gate_254.py' -not -path '*/.build/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
	n_runner=$(find "$repo" -name 'run_eval.py' -not -path '*/.build/*' -not -path '*/.git/*' | wc -l | tr -d ' ')

	if [ "$n_gate" != "1" ]; then
		echo "FAILED: $n_gate copies of brand_gate_254.py in this repository; there must be exactly 1." >&2
		find "$repo" -name 'brand_gate_254.py' -not -path '*/.build/*' -not -path '*/.git/*' >&2
		failures=$((failures + 1))
	fi
	if [ "$n_runner" != "1" ]; then
		echo "FAILED: $n_runner copies of run_eval.py in this repository; there must be exactly 1." >&2
		find "$repo" -name 'run_eval.py' -not -path '*/.build/*' -not -path '*/.git/*' >&2
		failures=$((failures + 1))
	fi

	# --- 2. the retired path, where it exists ----------------------------
	if [ ! -d "$retired" ]; then
		# NOT "ok". Absent is not the same as clean, and saying so is the whole
		# discipline this repository is built on.
		echo "  not evaluated — the retired path is not present on this host:"
		echo "      $retired"
		echo "    (expected on a CI runner; this check is meaningful on a developer machine)"
	else
		local stray
		stray=$(find "$retired" -name '*.py' ! -name 'brand_gate_254.py' | wc -l | tr -d ' ')
		if [ "$stray" != "0" ]; then
			echo "FAILED: the retired gate path has $stray python file(s) other than the refusing stub:" >&2
			find "$retired" -name '*.py' ! -name 'brand_gate_254.py' >&2
			failures=$((failures + 1))
		fi
		if [ -d "$retired/fixtures" ]; then
			echo "FAILED: $retired/fixtures exists — the fixtures live in this repository only." >&2
			failures=$((failures + 1))
		fi
		# The stub must REFUSE. A stub that answers is a second copy again.
		if [ -f "$retired/brand_gate_254.py" ]; then
			local rc=0
			python3 "$retired/brand_gate_254.py" /dev/null >/dev/null 2>&1 || rc=$?
			if [ "$rc" = "0" ]; then
				echo "FAILED: $retired/brand_gate_254.py exited 0 — it is answering, not refusing." >&2
				failures=$((failures + 1))
			else
				echo "  retired path present and correctly refusing (exit $rc)"
			fi
		fi
	fi

	if [ "$failures" -ne 0 ]; then
		echo "" >&2
		echo "the #254 gate must have exactly ONE home: $repo/Tools/brand-gate/" >&2
		return 1
	fi
	echo "  the #254 gate has exactly one home"
	return 0
}

# PROVEN ABLE TO FAIL. A check nobody has watched fail is not evidence — the
# same argument stage-binary.sh makes for itself.
# Global, NOT a local, and stage-binary.sh already carries this comment because
# it already made this mistake: the EXIT trap fires after the function's frame is
# gone, and under `set -u` a trap reaching for a dead local kills the script with
# "unbound variable" AFTER the report has printed -- a selftest that says "7 of 7
# correct" and then exits non-zero. Found here the first time this ran.
SELFTEST_TMP=""
selftest() {
	local failures=0 status tmp
	SELFTEST_TMP="$(mktemp -d)"
	tmp="$SELFTEST_TMP"
	trap 'rm -rf "$SELFTEST_TMP"' EXIT

	expect() {  # expect <pass|fail> <label> <repo> <retired>
		local want="$1" label="$2"
		status=0
		check "$3" "$4" >/dev/null 2>&1 || status=$?
		if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
			echo "SELFTEST FAILED: $label should have passed, exited $status" >&2; failures=$((failures+1))
		elif [ "$want" = fail ] && [ "$status" -eq 0 ]; then
			echo "SELFTEST FAILED: $label PASSED — this check cannot detect it" >&2; failures=$((failures+1))
		else
			echo "  ok — $label $want"
		fi
	}

	# A clean fixture repo: one of each, and a retired path holding a refusing stub.
	mkdir -p "$tmp/clean/Tools/brand-gate" "$tmp/retired"
	touch "$tmp/clean/Tools/brand-gate/brand_gate_254.py" "$tmp/clean/Tools/brand-gate/run_eval.py"
	printf 'import sys\nsys.exit(2)\n' > "$tmp/retired/brand_gate_254.py"

	echo "check-single-home.sh selftest"
	expect pass "one gate, one runner, a refusing stub" "$tmp/clean" "$tmp/retired"

	# THE DEFECT ITSELF: a second copy in the repo.
	mkdir -p "$tmp/dupe/Tools/brand-gate" "$tmp/dupe/artifacts/old"
	touch "$tmp/dupe/Tools/brand-gate/brand_gate_254.py" "$tmp/dupe/Tools/brand-gate/run_eval.py"
	touch "$tmp/dupe/artifacts/old/brand_gate_254.py"
	expect fail "a second brand_gate_254.py in the repository" "$tmp/dupe" "$tmp/retired"

	# The runner coming back on its own.
	mkdir -p "$tmp/dupe2/Tools/brand-gate" "$tmp/dupe2/x"
	touch "$tmp/dupe2/Tools/brand-gate/brand_gate_254.py" "$tmp/dupe2/Tools/brand-gate/run_eval.py"
	touch "$tmp/dupe2/x/run_eval.py"
	expect fail "a second run_eval.py in the repository" "$tmp/dupe2" "$tmp/retired"

	# The retired path re-growing a runner.
	mkdir -p "$tmp/retired_dirty"
	printf 'import sys\nsys.exit(2)\n' > "$tmp/retired_dirty/brand_gate_254.py"
	touch "$tmp/retired_dirty/run_eval.py"
	expect fail "the retired path growing a run_eval.py back" "$tmp/clean" "$tmp/retired_dirty"

	# The retired path re-growing fixtures.
	mkdir -p "$tmp/retired_fix/fixtures"
	printf 'import sys\nsys.exit(2)\n' > "$tmp/retired_fix/brand_gate_254.py"
	expect fail "the retired path growing fixtures back" "$tmp/clean" "$tmp/retired_fix"

	# THE SUBTLE ONE: the stub replaced by something that ANSWERS. This is how a
	# second copy comes back without adding a file.
	mkdir -p "$tmp/retired_answers"
	printf 'import sys\nsys.exit(0)\n' > "$tmp/retired_answers/brand_gate_254.py"
	expect fail "the stub replaced by a check that exits 0" "$tmp/clean" "$tmp/retired_answers"

	# And absence must not be read as failure — CI has no estate path.
	expect pass "the retired path simply not existing (a CI runner)" "$tmp/clean" "$tmp/nonexistent"

	if [ "$failures" -ne 0 ]; then
		echo "check-single-home.sh selftest: $failures of 7 cases wrong" >&2
		return 1
	fi
	echo "check-single-home.sh selftest: 7 cases, all correct"
}

case "${1:-}" in
	--selftest) selftest ;;
	*) check "$REPO" "$RETIRED" ;;
esac
