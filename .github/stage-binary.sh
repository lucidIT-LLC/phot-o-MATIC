#!/bin/bash
# Stage a built Walk front door into BINDIR and PROVE what landed there.
#
# WHY THIS FILE EXISTS — task #729, and it is an absence, not a bug.
#
# MEASURED 2026-09-12 on this host: the installed `walk` CLI reported 0.3.0
# while the installed `walk-mcp` reported 0.5.0, from the same source tree.
# Cause, measured by two runs independently: the Makefile had an `install-mcp`
# target and NO install target for the `walk` CLI at all. The front door with an
# install path stayed current; the one without drifted silently through two
# releases, and `make clean` deletes the release directory the stale binary was
# copied from, so nothing on the box could even say which build it came from.
#
# The consequence was not cosmetic. `walk contract --expect 0.5.0` exited 1
# (measured), so Andy's skill section 8.5 version gate read as FAILING for a
# reason that had nothing to do with the skill — the gate was working perfectly
# and reporting a real drift that nobody had a path to fix. And `walk contract`
# listed ZERO `coach.*` capabilities (measured) while walk-mcp told the same host
# they were declared: one host, two front doors, two different contracts.
#
# WHY IT IS A SHARED SCRIPT AND NOT A CHECK IN EACH TARGET. #740 put a real
# check on `install-mcp`: capture the version, fail on blank, fail on
# disagreement with Sources/WalkKit/Version.swift. That check was good and it
# was ALSO the problem — it existed in one place, so "both front doors are
# checked" depended on somebody remembering to copy it. A copied check is a
# check that can diverge, and the diverging front door is the exact defect
# #729 filed. One script, called by every install target, cannot diverge.
#
# Proven able to fail: `--selftest` exercises all four failure modes and the
# passing case, and fails if any of them comes out the other way. A check nobody
# has watched fail is not evidence.
#
# usage: stage-binary.sh <name> <built binary> <bindir>
#        stage-binary.sh --selftest
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stage() {
	local name="$1" built="$2" bindir="$3"
	# RESOLVED HERE, PER CALL, AND NOT ONCE AT LOAD TIME. It is overridable so
	# --selftest can point the check at a fixture tree instead of editing the
	# real Version.swift to watch the check fire. The first draft of this script
	# resolved it at load time, the override silently did nothing, and four of
	# five selftest cases passed FOR THE WRONG REASON — they failed against the
	# real 0.5.0 rather than against the fixture. A selftest that cannot be
	# steered is not a selftest, and this comment is here because the bug was in
	# the thing whose whole job is catching that shape.
	local version_source="${WALK_VERSION_SOURCE:-$REPO/Sources/WalkKit/Version.swift}"

	if [ ! -x "$built" ]; then
		echo "install FAILED: $built is not an executable file." >&2
		echo "Nothing was staged. Run 'make release' first." >&2
		return 1
	fi

	# The declared version is read FIRST, before anything is copied. If the
	# source of truth cannot be read there is no way to judge what lands in
	# BINDIR, and staging an unjudgeable binary is how 0.3.0 sat there for two
	# releases.
	local declared
	declared="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$version_source")"
	if [ -z "$declared" ]; then
		echo "install FAILED: cannot read Walk.version out of" >&2
		echo "  $version_source" >&2
		echo "so there is nothing to check the installed $name against. Nothing staged." >&2
		return 1
	fi

	mkdir -p "$bindir"

	# REMOVE THE DESTINATION FIRST. `cp` OVER A MACH-O IN PLACE GETS IT SIGKILLED.
	#
	# MEASURED 2026-09-13, isolated in three runs on this host:
	#   cp over the existing binary, content CHANGED -> `--version` exit 137 (SIGKILL)
	#   rm -f, then cp                               -> exit 0, prints 0.5.7
	#   cp over again, content now IDENTICAL         -> exit 0
	#
	# The kernel caches a code-signature validation against the vnode. Writing new
	# bytes into the same inode leaves that cache describing a binary that is no
	# longer there, and macOS kills the process rather than running it. It only
	# fires when the CONTENT changes, which is to say: on every real re-stage after
	# a source edit, and never on the re-run someone does to reproduce it.
	#
	# THE FAILURE WORE THE WRONG NAME UNTIL IT WAS MEASURED. The check below
	# reported "does not report a version", which reads as a broken build -- the
	# build product was fine and printed its version correctly the whole time. The
	# staging step was the only thing wrong, and the report pointed at the binary.
	rm -f "$bindir/$name"
	cp "$built" "$bindir/$name"

	local installed
	installed="$("$bindir/$name" --version 2>/dev/null || true)"

	if [ -z "$installed" ]; then
		echo "install FAILED: $bindir/$name does not report a version." >&2
		echo "The copy succeeded, but a binary that cannot identify itself makes any" >&2
		echo "success message a claim rather than a fact, so this fails instead." >&2
		echo "#740: an unguarded command substitution here printed 'walk-mcp  installed'" >&2
		echo "and reported SUCCESS, at the one moment the operator needs the version." >&2
		return 1
	fi

	if [ "$installed" != "$declared" ]; then
		echo "install FAILED: $bindir/$name reports $installed and this source tree" >&2
		echo "declares $declared. Something staged a build other than this one, and an" >&2
		echo "install that silently does not update is the whole of task #729." >&2
		return 1
	fi

	echo ""
	echo "$name $installed installed at $bindir/$name"
}

# Global, NOT a local: the EXIT trap fires after the function's frame is gone,
# and under `set -u` a trap reaching for a dead local kills the script with
# "unbound variable" after the report has already printed.
SELFTEST_TMP=""
selftest() {
	local status failures=0
	SELFTEST_TMP="$(mktemp -d)"
	local tmp="$SELFTEST_TMP"
	trap 'rm -rf "$SELFTEST_TMP"' EXIT

	# A version source the fixtures are judged against, so the real one is not
	# touched to make the check fire.
	mkdir -p "$tmp/src"
	printf 'public enum Walk {\n    public static let version = "9.9.9"\n}\n' > "$tmp/src/Version.swift"

	mk() {  # mk <path> <what --version prints; empty for nothing>
		printf '#!/bin/sh\n[ "$1" = "--version" ] && printf %%s "%s"\nexit 0\n' "$2" > "$1"
		chmod +x "$1"
	}

	expect() {  # expect <pass|fail> <label> <name> <built> — runs stage()
		local want="$1" label="$2" name="$3" built="$4"
		status=0
		WALK_VERSION_SOURCE="$tmp/src/Version.swift" \
			stage "$name" "$built" "$tmp/bin" >/dev/null 2>&1 || status=$?
		if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
			echo "SELFTEST FAILED: $label should have passed, exited $status" >&2
			failures=$((failures + 1))
		elif [ "$want" = fail ] && [ "$status" -eq 0 ]; then
			echo "SELFTEST FAILED: $label PASSED — this check cannot detect it" >&2
			failures=$((failures + 1))
		else
			echo "  ok — $label $want"
		fi
	}

	mk "$tmp/good" "9.9.9"
	mk "$tmp/silent" ""
	mk "$tmp/stale" "0.3.0"

	echo "stage-binary.sh selftest"
	expect pass "a binary whose version matches the tree" walk "$tmp/good"
	# #740's defect: a binary that cannot say what it is.
	expect fail "a binary that reports no version" walk "$tmp/silent"
	# #729's defect: the install that silently did not update.
	expect fail "a binary reporting 0.3.0 against a 9.9.9 tree" walk "$tmp/stale"
	expect fail "a built path that does not exist" walk "$tmp/absent"

	# And the unreadable source of truth.
	printf 'public enum Walk { }\n' > "$tmp/src/Version.swift"
	expect fail "a Version.swift declaring no version" walk "$tmp/good"

	if [ "$failures" -ne 0 ]; then
		echo "stage-binary.sh selftest: $failures of 5 cases wrong" >&2
		return 1
	fi
	echo "stage-binary.sh selftest: 5 cases, all correct"
}

case "${1:-}" in
	--selftest) selftest ;;
	"") echo "usage: stage-binary.sh <name> <built binary> <bindir> | --selftest" >&2; exit 2 ;;
	*)
		[ "$#" -eq 3 ] || { echo "usage: stage-binary.sh <name> <built binary> <bindir>" >&2; exit 2; }
		stage "$1" "$2" "$3"
		;;
esac
