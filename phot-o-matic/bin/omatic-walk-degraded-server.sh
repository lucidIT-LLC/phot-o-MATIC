#!/bin/sh
# omatic-walk-degraded-server.sh — a real MCP server that advertises ZERO tools
# and says why.
#
# WHY THIS EXISTS AND WHY IT IS NOT A `exit 1`.
#
# When the launcher cannot start the Walk engine, the honest outcomes are two
# and they look identical to a host that gets nothing: "this plugin is broken on
# your machine, here is the reason" and "this plugin is not configured yet". A
# spawn that dies produces the second reading for a first-cause every time. That
# is absence indistinguishable from success, in the form where it costs a
# support ticket instead of a bug.
#
# So: speak MCP, hand back an empty tool list, and put the reason in the one
# field a host reads before it chooses anything — `instructions`.
#
# The engine's real reason for being absent arrives in OMATIC_WALK_ERROR.

set -u

REASON=${OMATIC_WALK_ERROR:-"the Walk engine could not be started, and the launcher did not say why — which is itself a defect worth reporting."}
PLUGIN_VERSION=${OMATIC_WALK_PLUGIN_VERSION:-unknown}

# JSON string escaping for the two characters that can actually appear in these
# messages (paths with quotes, and backslashes). Newlines are not emitted.
esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

REASON_JSON=$(esc "$REASON")

INSTRUCTIONS="Walk is installed but NOT RUNNING on this host, so it has no tools to offer and none of its measurements are available. This is a refusal with a cause, not an empty result. Reason: ${REASON} Plugin version ${PLUGIN_VERSION}. Do not substitute an estimate, a guess, or a verdict of your own for what Walk would have measured — report this reason to the operator instead."
INSTRUCTIONS_JSON=$(esc "$INSTRUCTIONS")

send() { printf '%s\n' "$1"; }

# Line-oriented JSON-RPC over stdio. Only the three methods a host needs in
# order to display the refusal are answered; everything else gets a proper
# error object rather than silence.
while IFS= read -r line; do
	[ -n "$line" ] || continue

	id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
	[ -n "$id" ] || id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/"\1"/p' | head -1)

	case "$line" in
		*'"method"'*'"initialize"'*)
			send "{\"jsonrpc\":\"2.0\",\"id\":${id:-0},\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"walk-degraded\",\"version\":\"${PLUGIN_VERSION}\"},\"instructions\":\"${INSTRUCTIONS_JSON}\"}}"
			;;
		*'"method"'*'"notifications/initialized"'*)
			: # a notification carries no id and takes no reply
			;;
		*'"method"'*'"tools/list"'*)
			send "{\"jsonrpc\":\"2.0\",\"id\":${id:-0},\"result\":{\"tools\":[]}}"
			;;
		*'"method"'*'"tools/call"'*)
			send "{\"jsonrpc\":\"2.0\",\"id\":${id:-0},\"error\":{\"code\":-32000,\"message\":\"Walk is not running on this host: ${REASON_JSON}\"}}"
			;;
		*'"id"'*)
			send "{\"jsonrpc\":\"2.0\",\"id\":${id:-0},\"error\":{\"code\":-32601,\"message\":\"Walk is not running on this host: ${REASON_JSON}\"}}"
			;;
		*)
			: # a notification we do not handle; silence is the correct reply
			;;
	esac
done
