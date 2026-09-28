#!/bin/bash
# Every place this repository states a license must say what LICENSE says.
#
# WHY (task #1013 P4, Smith's audit, measured 2026-09-28). LICENSE grants no
# license at all, and says BUSL-1.1 was rejected. At the same moment the Claude
# plugin manifest, the Codex plugin manifest and the marketplace entry declared
# BUSL-1.1, and the app's copyright string and the README declared MIT. Four
# statements, three answers. The LICENSE file was itself rewritten on
# 2026-09-14 because it had said MIT while the manifests said BUSL; fixing the
# one file by hand left the other copies to drift, and they had.
#
# This check does NOT choose a license — task #573 does, with counsel. It holds
# every copy to whatever LICENSE currently says. When #573 lands, LICENSE and
# EXPECTED below change together, in one commit, and this goes green again.
#
# usage: check-license.sh [repo root]      (default: the repository this is in)
#        check-license.sh --selftest       (proves it can fail)
set -uo pipefail

EXPECTED="LicenseRef-lucidIT-no-license-granted"
LICENSE_MARKER="NO LICENCE IS GRANTED"
# License identifiers LICENSE does not grant. Named literally on purpose: the
# check has to recognize the thing it forbids.
FORBIDDEN='\b(MIT|BUSL-1\.1|BUSL|Apache-2\.0|GPL-[0-9]|AGPL|LGPL|BSD-[0-9]|MPL-2\.0|PolyForm)\b'

check() {
  local root="$1" fail=0
  [ -f "$root/LICENSE" ] || { echo "license-check FAILED: $root/LICENSE is missing" >&2; return 1; }
  if ! grep -q "$LICENSE_MARKER" "$root/LICENSE"; then
    echo "license-check FAILED: LICENSE no longer says \"$LICENSE_MARKER\" — if #573 chose a license, update EXPECTED in this script in the same commit" >&2
    fail=1
  fi

  for m in .claude-plugin/marketplace.json .agents/plugins/marketplace.json \
           phot-o-matic/.claude-plugin/plugin.json phot-o-matic/.codex-plugin/plugin.json; do
    [ -f "$root/$m" ] || continue
    local bad
    bad=$(python3 - "$root/$m" "$EXPECTED" <<'PY'
import json, sys
path, expected = sys.argv[1], sys.argv[2]
found = []
def walk(node, where):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "license":
                if v != expected:
                    found.append("%s = %r" % (where + "." + k, v))
            else:
                walk(v, where + "." + k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (where, i))
walk(json.load(open(path)), "$")
print("\n".join(found))
PY
)
    if [ -n "$bad" ]; then
      echo "license-check FAILED: $m declares a license LICENSE does not grant (expected $EXPECTED):" >&2
      echo "$bad" | sed 's/^/    /' >&2
      fail=1
    fi
  done

  local pbx="$root/App/Walk.xcodeproj/project.pbxproj"
  if [ -f "$pbx" ] && grep 'NSHumanReadableCopyright' "$pbx" | grep -qE "$FORBIDDEN"; then
    echo "license-check FAILED: the app's NSHumanReadableCopyright names a license LICENSE does not grant:" >&2
    grep -n 'NSHumanReadableCopyright' "$pbx" | sed 's/^/    /' >&2
    fail=1
  fi

  if [ -f "$root/README.md" ]; then
    local section
    section=$(awk '/^## License/{on=1; next} /^## /{on=0} on' "$root/README.md")
    if [ -z "$section" ]; then
      echo "license-check FAILED: README.md has no '## License' section" >&2; fail=1
    elif echo "$section" | grep -v "$EXPECTED" | grep -qE "$FORBIDDEN"; then
      echo "license-check FAILED: README's License section names a license LICENSE does not grant" >&2; fail=1
    fi
  fi
  return $fail
}

if [ "${1:-}" = "--selftest" ]; then
  here="$(cd "$(dirname "$0")/.." && pwd)"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  plant() {
    rm -rf "$tmp/r"; mkdir -p "$tmp/r"
    (cd "$here" && tar cf - LICENSE README.md .claude-plugin .agents phot-o-matic/.claude-plugin \
       phot-o-matic/.codex-plugin App/Walk.xcodeproj/project.pbxproj) | (cd "$tmp/r" && tar xf -)
  }
  status=0
  plant
  check "$tmp/r" >/dev/null 2>&1 || { echo "selftest FAILED: the clean tree did not pass"; status=1; }
  plant; sed -i '' "s/\"license\": \"$EXPECTED\"/\"license\": \"BUSL-1.1\"/" "$tmp/r/phot-o-matic/.codex-plugin/plugin.json"
  check "$tmp/r" >/dev/null 2>&1 && { echo "selftest FAILED: a BUSL-1.1 manifest passed"; status=1; }
  plant; sed -i '' 's/All rights reserved\./MIT/' "$tmp/r/App/Walk.xcodeproj/project.pbxproj"
  check "$tmp/r" >/dev/null 2>&1 && { echo "selftest FAILED: an MIT app copyright passed"; status=1; }
  plant; printf '\n## License\n\nMIT\n' > "$tmp/r/README.md"
  check "$tmp/r" >/dev/null 2>&1 && { echo "selftest FAILED: an MIT README passed"; status=1; }
  plant; echo "MIT License" > "$tmp/r/LICENSE"
  check "$tmp/r" >/dev/null 2>&1 && { echo "selftest FAILED: a LICENSE that changed alone passed"; status=1; }
  [ $status -eq 0 ] && echo "license-check selftest OK — clean passes, 4 planted contradictions each refused"
  exit $status
fi

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if check "$root"; then
  echo "license-check OK — every manifest, the README and the app copyright agree with LICENSE ($EXPECTED)"
else
  exit 1
fi
