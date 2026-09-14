#!/bin/sh
# omatic-walk-launch.sh — the process an MCP host spawns for the Walk plugin.
#
# WHY A LAUNCHER AND NOT A BARE BINARY NAME IN THE MANIFEST.
#
# A manifest declaring "command": "walk-mcp" works in every terminal-launched
# MCP host and fails in every GUI-launched one: a GUI app inherits the minimal
# system PATH (/usr/bin:/bin:/usr/sbin:/sbin), so a bare name is unresolvable
# and the server is never spawned. The host then reports no tools, which is
# INDISTINGUISHABLE from a plugin that is merely unconfigured. That is this
# factory's most-repeated defect class — absence indistinguishable from success
# — and it is task #735's constraint on this plugin.
#
# The same argument applies to an absolute path baked into the manifest: the
# plugin root is wherever the host cloned it, and only the host knows.
#
# PLUGIN ROOT IS RESOLVED FROM $0, NOT FROM AN ENVIRONMENT VARIABLE, on purpose.
# The manifest passes ${CLAUDE_PLUGIN_ROOT} (the documented spelling — see the
# note in .mcp.json), but a launcher that TRUSTS that variable cannot tell an
# unexpanded placeholder from a real path. Resolving from $0 means the launcher
# is correct even when the caller's expansion is wrong, and the check below
# reports the disagreement rather than dying on it.
#
# Usage from a manifest:
#   "command": "/bin/sh"
#   "args": ["${CLAUDE_PLUGIN_ROOT}/bin/omatic-walk-launch.sh"]

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd) || exit 1

SERVER="$SCRIPT_DIR/walk-mcp"
DEGRADED="$SCRIPT_DIR/omatic-walk-degraded-server.sh"

OMATIC_WALK_PLUGIN_ROOT="$PLUGIN_ROOT"
export OMATIC_WALK_PLUGIN_ROOT

fail() {
	OMATIC_WALK_ERROR="$1"
	export OMATIC_WALK_ERROR
	OMATIC_WALK_PLUGIN_VERSION=$(
		sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
			"$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1
	)
	export OMATIC_WALK_PLUGIN_VERSION="${OMATIC_WALK_PLUGIN_VERSION:-unknown}"
	# A degraded server rather than a silent exit. A host that gets nothing back
	# shows "no tools", which reads as "not set up yet". A host that gets a
	# server advertising zero tools and a REASON shows the reason.
	if [ -r "$DEGRADED" ]; then
		exec /bin/sh "$DEGRADED"
	fi
	echo "[o-matic-walk] FATAL: $OMATIC_WALK_ERROR, and the degraded server at $DEGRADED is missing." >&2
	exit 1
}

# ---------------------------------------------------------------------------
# The declared floor, checked rather than assumed.
#
# Walk is a Swift binary linking Vision, CoreML and AVFoundation and is built
# for arm64 macOS 26. It cannot run on Intel and it cannot run on an older
# macOS. The plugin manifest DECLARES that floor; this is where the declaration
# is enforced, so a host below it gets a sentence instead of a dyld error.
# ---------------------------------------------------------------------------

MIN_MACOS_MAJOR=26

case "$(uname -s 2>/dev/null)" in
	Darwin) ;;
	*) fail "Walk runs on macOS only — this host reports $(uname -s 2>/dev/null || echo 'an unknown system'). The engine links Apple's Vision and AVFoundation frameworks and has no port." ;;
esac

ARCH=$(uname -m 2>/dev/null || echo unknown)
case "$ARCH" in
	arm64) ;;
	*) fail "Walk ships an arm64 binary and this host reports $ARCH. Apple silicon is required; the on-device Vision classification this plugin exists for is not available to it on Intel." ;;
esac

OS_MAJOR=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
case "$OS_MAJOR" in
	''|*[!0-9]*)
		# Unreadable is NOT the same as too old. Say so and continue rather than
		# refusing on an instrument's null — the exact inversion this factory
		# has named three times.
		echo "[o-matic-walk] note: could not read the macOS version from sw_vers; proceeding. The declared floor is macOS $MIN_MACOS_MAJOR." >&2
		;;
	*)
		if [ "$OS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
			fail "Walk requires macOS $MIN_MACOS_MAJOR or later and this host reports macOS $(sw_vers -productVersion 2>/dev/null). The declared floor is in the plugin manifest; this is that floor enforced."
		fi
		;;
esac

[ -f "$SERVER" ] || fail "the Walk engine is not present at $SERVER. This plugin ships a prebuilt binary; a checkout missing it is incomplete. Run 'make stage-plugin' in the Walk source tree."
[ -x "$SERVER" ] || fail "$SERVER exists but is not executable. Restore the mode bit with: chmod +x '$SERVER'"

# Gatekeeper quarantine is the one failure that looks like a crash rather than a
# refusal, so it is named here rather than left to dyld.
if command -v xattr >/dev/null 2>&1; then
	if xattr "$SERVER" 2>/dev/null | grep -q 'com.apple.quarantine'; then
		fail "$SERVER carries com.apple.quarantine and macOS will refuse to run it. Clear it with: xattr -d com.apple.quarantine '$SERVER'"
	fi
fi

exec "$SERVER" "$@"
