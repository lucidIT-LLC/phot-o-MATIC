#!/bin/sh
# Task #740 defect 1: the per-candidate `sigma` field must NOT be emitted on any
# output surface, and each machine-readable surface must carry the
# `sigmaNotEmitted` notice that says why.
#
# WHY A SOURCE-LEVEL CHECK. The emitters live in two executables (walk, walk-mcp)
# and the app, no fixture video ships in this repository, and the JSON is built
# by hand from format strings. So this asserts the SHAPE of the emitters in
# source, both directions: the field pattern is absent from every per-candidate
# emitter, and the notice is present in every machine-readable one. It is a
# weaker instrument than a wire test and it says so; the wire itself was
# measured on clip 0012 on 2026-09-25 (see CHANGELOG 0.8.0). What this gate
# prevents is the quiet return of the column — the exact way it arrived.
#
# --selftest plants both defects in copies and requires the check to fail on each.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

check() {
    root="$1"; status=0
    cli="$root/Sources/walk/Commands.swift"
    mcp="$root/Sources/walk-mcp/Tools.swift"
    model="$root/App/WalkApp/ProofSheetModel.swift"
    view="$root/App/WalkApp/ProofSheetView.swift"
    readme="$root/README.md"
    for f in "$cli" "$mcp" "$model" "$view" "$readme"; do
        [ -f "$f" ] || { echo "::error::sheet-check: $f is missing"; return 1; }
    done
    # Absent: a per-candidate sigma emission. The CLI JSON writes a literal
    # \"sigma\": into the event; the MCP builds "sigma": .double(c.sigma); the
    # text sheet formats e.sigma; the app model carries moment.sigma.
    grep -n '\\"sigma\\"' "$cli" >/dev/null && { echo "::error::sheet-check: $cli emits a per-event \"sigma\" key in --json"; status=1; }
    grep -n 'e\.sigma' "$cli" | grep -v 'sigma: e.sigma, mergedFrames' >/dev/null && { echo "::error::sheet-check: $cli prints e.sigma on the text sheet"; status=1; }
    grep -n '"sigma": *\.double(c\.sigma)' "$mcp" >/dev/null && { echo "::error::sheet-check: $mcp emits sigma in the MCP candidate object"; status=1; }
    grep -n 'moment\.sigma\|let sigma:' "$model" "$view" >/dev/null && { echo "::error::sheet-check: the app still carries or renders a per-candidate sigma"; status=1; }
    grep -n '^  frame .* sigma ' "$readme" >/dev/null && { echo "::error::sheet-check: README sample output still shows a sigma column"; status=1; }
    # Present: the notice, on both machine-readable surfaces.
    grep -q 'sigmaNotEmitted' "$cli" || { echo "::error::sheet-check: $cli lacks the sigmaNotEmitted notice"; status=1; }
    grep -q 'sigmaNotEmitted' "$mcp" || { echo "::error::sheet-check: $mcp lacks the sigmaNotEmitted notice"; status=1; }
    # And the old key must not linger under its old name, which would read as
    # the field still existing.
    grep -n 'sigmaDerivation' "$cli" "$mcp" >/dev/null && { echo "::error::sheet-check: sigmaDerivation survives; the field it described is gone"; status=1; }
    return $status
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    plant() { rm -rf "$tmp/t"; mkdir -p "$tmp/t/Sources/walk" "$tmp/t/Sources/walk-mcp" "$tmp/t/App/WalkApp"
              cp "$ROOT/Sources/walk/Commands.swift" "$tmp/t/Sources/walk/"
              cp "$ROOT/Sources/walk-mcp/Tools.swift" "$tmp/t/Sources/walk-mcp/"
              cp "$ROOT/App/WalkApp/ProofSheetModel.swift" "$ROOT/App/WalkApp/ProofSheetView.swift" "$tmp/t/App/WalkApp/"
              cp "$ROOT/README.md" "$tmp/t/"; }
    fails=0
    plant; check "$tmp/t" >/dev/null 2>&1 || { echo "selftest: clean tree must pass"; fails=1; }
    plant; printf '%s\n' '        "sigma": .double(c.sigma),' >> "$tmp/t/Sources/walk-mcp/Tools.swift"
    check "$tmp/t" >/dev/null 2>&1 && { echo "selftest: a planted MCP sigma field was NOT caught"; fails=1; }
    plant; printf '%s\n' 'o += String(format: "\"sigma\": %.4f", e.sigma)' >> "$tmp/t/Sources/walk/Commands.swift"
    check "$tmp/t" >/dev/null 2>&1 && { echo "selftest: a planted CLI sigma field was NOT caught"; fails=1; }
    plant; sed -i '' 's/sigmaNotEmitted/sigmaSomethingElse/g' "$tmp/t/Sources/walk-mcp/Tools.swift"
    check "$tmp/t" >/dev/null 2>&1 && { echo "selftest: a removed MCP notice was NOT caught"; fails=1; }
    plant; printf '%s\n' '    let sigma: Double' >> "$tmp/t/App/WalkApp/ProofSheetModel.swift"
    check "$tmp/t" >/dev/null 2>&1 && { echo "selftest: a planted app sigma field was NOT caught"; fails=1; }
    [ $fails -eq 0 ] && echo "sheet-check selftest OK — clean tree passes, four planted defects each fail"
    exit $fails
fi

check "$ROOT" && echo "  sheet-check OK — no per-candidate sigma on any surface; sigmaNotEmitted notice present"
