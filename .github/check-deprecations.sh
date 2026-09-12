#!/bin/bash
# Inventory every deprecation diagnostic in a build log and compare it against
# .github/deprecations-allowed.txt. See that file for why this is an inventory
# and not a keyword grep.
#
# Plain POSIX-ish bash on purpose: macOS ships bash 3.2, which has no `mapfile`.
# The first draft of this script used one and failed on this very machine — a
# check that cannot run is worse than no check, because it reports nothing and
# looks like nothing to report.
set -uo pipefail

LOG="${1:?usage: check-deprecations.sh <build.log>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOW="$DIR/deprecations-allowed.txt"
[ -f "$ALLOW" ] || { echo "::error::$ALLOW is missing"; exit 1; }
[ -f "$LOG" ]   || { echo "::error::build log $LOG is missing — the build must be captured with tee"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Normalize: keep only the diagnostic text from "warning:" onward, drop the
# compiler's source-quote lines (which repeat the same text behind a backtick),
# strip ANSI colour and the trailing diagnostic-name link, and de-duplicate.
grep -E "warning:.*[Dd]eprecat" "$LOG" \
  | sed -E 's/'$'\033''\[[0-9;]*m//g' \
  | sed -E 's/'$'\033''\]8;;[^'$'\033'']*'$'\033''\\\\//g' \
  | grep -v '`-' \
  | sed -E 's/.*(warning: )/\1/' \
  | sed -E 's/ \[#DeprecatedDeclaration\]//' \
  | sed -E 's/ \(Define CI_SILENCE_GL_DEPRECATION[^)]*\)//' \
  | sort -u > "$WORK/found"

grep -vE '^[[:space:]]*(#|$)' "$ALLOW" > "$WORK/allowed" || true

status=0

# 1. Anything found that no allowlist entry covers fails the build.
if [ -s "$WORK/allowed" ]; then
  grep -vF -f "$WORK/allowed" "$WORK/found" > "$WORK/unlisted" || true
else
  cp "$WORK/found" "$WORK/unlisted"
fi
if [ -s "$WORK/unlisted" ]; then
  sed 's/^/  UNLISTED: /' "$WORK/unlisted"
  echo "::error::a deprecation diagnostic appeared that is not in .github/deprecations-allowed.txt — resolve it, or add it there WITH A REASON AND AN OWNER"
  status=1
fi

# 2. An allowlist entry that no longer appears ALSO fails. An allowlist is a
#    record of live exceptions; one that keeps dead entries is the same rot as a
#    retired document cited as current authority.
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  if ! grep -qF -- "$pattern" "$WORK/found"; then
    echo "  STALE: $pattern"
    echo "::error::that deprecation no longer occurs in the build — delete the entry from .github/deprecations-allowed.txt"
    status=1
  fi
done < "$WORK/allowed"

if [ $status -eq 0 ]; then
  echo "deprecation inventory clean: $(grep -c . "$WORK/found") distinct diagnostic(s), all accounted for:"
  sed 's/^/  /' "$WORK/found"
fi
exit $status
