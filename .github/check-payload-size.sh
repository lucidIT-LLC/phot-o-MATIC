#!/bin/bash
# WHAT ACTUALLY SHIPS, ASSERTED IN BYTES.
#
# WHY THIS EXISTS. MEASURED 2026-09-14 on the installed plugin cache:
#
#   ~/.claude/plugins/cache/o-matic-walk/walk/0.5.7   494 MB
#     .build/   492 MB   <- the Swift build tree, PUBLISHED
#     bin/      1.3 MB   <- the actual binary, correct
#
# It had been reported as "1.4 MB, proven". That report was not wrong about what
# it measured — `bin/walk-mcp` is 1,385,032 bytes — it was wrong about what
# SHIPPED, because nothing looked at the total. A number correct about the thing
# measured and wrong about the thing delivered is this repository's whole
# subject, and it had reached the one surface a customer downloads.
#
# TWO CEILINGS, BECAUSE THERE ARE TWO INSTALL PATHS AND THEY OBEY DIFFERENT RULES.
# MEASURED, and the distinction is the finding:
#
#   A GITHUB MARKETPLACE INSTALL CLONES THE REPOSITORY, so `.gitignore` governs
#   and `.build/` never leaves this machine. Measured clone payload: 2.5 MB
#   across 83 tracked files. That is the real ship path under decision #534.
#
#   A LOCAL-PATH MARKETPLACE INSTALL COPIES THE WORKING DIRECTORY and honours no
#   ignore file at all. That is where the 494 MB came from — `claude plugin
#   marketplace add <path>` during development. Nothing in the repository can
#   configure that away, so it is ASSERTED here instead.
#
# So `.gitignore` is authoritative for what ships and is fixed; this check is
# authoritative for whether anyone notices when that stops being true.
#
# usage: check-payload-size.sh [--selftest]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ceilings, chosen from the honest payload with headroom rather than from the
# current number — a ceiling set at what happens to be there today cannot catch
# a regression that arrives tomorrow.
#
#   clone today 2.5 MB (binary 1.3 + sources/tests/tools ~0.9 + docs ~0.12)
#   -> 8 MB leaves room for the binary to grow and a criteria set to ship.
#   working tree today ~5 MB clean; .build alone is 492 MB
#   -> 64 MB is far above any legitimate source tree and far below a build tree.
CLONE_CEILING_MB="${WALK_CLONE_CEILING_MB:-8}"
TREE_CEILING_MB="${WALK_TREE_CEILING_MB:-64}"

# THE CLONE CEILING IS ALWAYS FATAL. It judges what a GitHub marketplace install
# actually carries, and nothing legitimate pushes it over.
#
# THE TREE CEILING IS REPORTED ALWAYS AND FATAL ONLY UNDER --strict, and that
# asymmetry is deliberate rather than a softening. `.build/` is SUPPOSED to exist
# on a developer machine; making its presence fail every build would produce a
# check that is red on every healthy tree, which is a check people route around.
# It is fatal where it actually matters: before a LOCAL-PATH marketplace install,
# which copies the tree verbatim and is how 494 MB once shipped as "1.4 MB".
# Either way THE NUMBER IS ALWAYS PRINTED, so the condition can never again be
# invisible -- being unmissable is the control, not being fatal.
STRICT="${WALK_PAYLOAD_STRICT:-0}"

kb_of_clone() {  # what a git clone carries: tracked + untracked-not-ignored
	local root="$1"
	{ git -C "$root" ls-files -z 2>/dev/null
	  git -C "$root" ls-files -z --others --exclude-standard 2>/dev/null
	} | xargs -0 -I{} sh -c 'wc -c < "$1" 2>/dev/null || echo 0' _ "$root"/{} \
	  | awk '{t+=$1} END {printf "%d", (t+1023)/1024}'
}

kb_of_tree() {  # what a local-path install copies: everything, ignore files and all
	du -sk "$1" 2>/dev/null | awk '{print $1}'
}

report() {
	local root="$1" fail=0 clone_kb tree_kb clone_mb tree_mb
	clone_kb=$(kb_of_clone "$root"); [ -n "$clone_kb" ] || clone_kb=0
	tree_kb=$(kb_of_tree "$root");   [ -n "$tree_kb" ]  || tree_kb=0
	clone_mb=$(( clone_kb / 1024 )); tree_mb=$(( tree_kb / 1024 ))

	printf "  clone payload (git-tracked + untracked, what a marketplace install gets): %d KB (%d MB), ceiling %d MB\n" \
		"$clone_kb" "$clone_mb" "$CLONE_CEILING_MB"
	printf "  working tree  (what a LOCAL-PATH install copies verbatim):                %d KB (%d MB), ceiling %d MB\n" \
		"$tree_kb" "$tree_mb" "$TREE_CEILING_MB"

	if [ "$clone_kb" -gt $(( CLONE_CEILING_MB * 1024 )) ]; then
		echo "FAILED: the clone payload is ${clone_mb} MB, over the ${CLONE_CEILING_MB} MB ceiling." >&2
		echo "  Something large is TRACKED or untracked-and-not-ignored. Largest first:" >&2
		git -C "$root" ls-files -z | xargs -0 -I{} sh -c 'printf "%s %s\n" "$(wc -c < "$1" 2>/dev/null || echo 0)" "$1"' _ "$root"/{} \
			| sort -rn | head -5 | awk '{printf "    %10d  %s\n", $1, $2}' >&2
		fail=1
	fi

	if [ "$tree_kb" -gt $(( TREE_CEILING_MB * 1024 )) ]; then
		local level="WARNING"; [ "$STRICT" = "1" ] && level="FAILED"
		echo "$level: the working tree is ${tree_mb} MB, over the ${TREE_CEILING_MB} MB ceiling." >&2
		echo "  A GitHub install is unaffected (.gitignore governs), but a LOCAL-PATH" >&2
		echo "  marketplace copies this verbatim — that is how 494 MB once shipped as" >&2
		echo "  '1.4 MB'. Largest directories:" >&2
		du -sk "$root"/* "$root"/.[!.]* 2>/dev/null | sort -rn | head -5 \
			| awk '{printf "    %8d KB  %s\n", $1, $2}' >&2
		if [ "$STRICT" = "1" ]; then
			fail=1
		else
			echo "  (not fatal here: .build/ belongs on a developer machine. Run with" >&2
			echo "   --strict, or WALK_PAYLOAD_STRICT=1, before a local-path install.)" >&2
		fi
	fi

	[ "$fail" -eq 0 ] && echo "  payload size OK"
	return "$fail"
}

# PROVEN ABLE TO FAIL. A ceiling nobody has watched reject something is not a
# ceiling — the same argument stage-binary.sh and check-single-home.sh make.
selftest() {
	local failures=0 status
	SELFTEST_TMP="$(mktemp -d)"
	trap 'rm -rf "$SELFTEST_TMP"' EXIT
	local tmp="$SELFTEST_TMP"

	mkdir -p "$tmp/clean"; ( cd "$tmp/clean" && git init -q . )
	printf 'small\n' > "$tmp/clean/file.txt"
	( cd "$tmp/clean" && git add -A )

	expect() {  # expect <pass|fail> <label> <root> <cloneMB> <treeMB>
		local want="$1" label="$2"
		status=0
		CLONE_CEILING_MB="$4" TREE_CEILING_MB="$5" STRICT="${6:-1}" report "$3" >/dev/null 2>&1 || status=$?
		if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
			echo "SELFTEST FAILED: $label should have passed" >&2; failures=$((failures+1))
		elif [ "$want" = fail ] && [ "$status" -eq 0 ]; then
			echo "SELFTEST FAILED: $label PASSED — this ceiling cannot reject anything" >&2; failures=$((failures+1))
		else
			echo "  ok — $label $want"
		fi
	}

	echo "check-payload-size.sh selftest"
	expect pass "a small clean tree under both ceilings" "$tmp/clean" 8 64

	# A BIG IGNORED DIRECTORY: invisible to a clone, fatal to a local-path install.
	# This is the 494 MB case, in miniature.
	mkdir -p "$tmp/clean/.build"
	mkfile -n 6m "$tmp/clean/.build/blob" 2>/dev/null || dd if=/dev/zero of="$tmp/clean/.build/blob" bs=1m count=6 2>/dev/null
	printf '.build/\n' > "$tmp/clean/.gitignore"
	( cd "$tmp/clean" && git add -A 2>/dev/null )
	expect fail "a 6 MB ignored build tree, --strict, against a 4 MB tree ceiling" "$tmp/clean" 8 4 1
	expect pass "the same tree WITHOUT --strict (a developer's .build must not fail a build)" "$tmp/clean" 8 4 0
	expect pass "the same tree when the clone ceiling alone is judged" "$tmp/clean" 8 64

	# A BIG TRACKED FILE: this one a clone really does carry.
	mkfile -n 6m "$tmp/clean/huge.bin" 2>/dev/null || dd if=/dev/zero of="$tmp/clean/huge.bin" bs=1m count=6 2>/dev/null
	( cd "$tmp/clean" && git add -A 2>/dev/null )
	expect fail "a 6 MB tracked file against a 2 MB clone ceiling" "$tmp/clean" 2 64

	if [ "$failures" -ne 0 ]; then
		echo "check-payload-size.sh selftest: $failures of 5 cases wrong" >&2
		return 1
	fi
	echo "check-payload-size.sh selftest: 5 cases, all correct"
}

case "${1:-}" in
	--selftest) selftest ;;
	--strict) STRICT=1; echo "payload size (STRICT: the working tree is fatal too):"; report "$REPO" ;;
	*) echo "payload size, against what each install path actually carries:"; report "$REPO" ;;
esac
