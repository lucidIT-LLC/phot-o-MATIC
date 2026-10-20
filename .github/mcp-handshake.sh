#!/bin/bash
# Drive walk-mcp over stdio the way a host does, and assert what comes back.
#
# BOTH ERAS, AND THAT IS NOT CAUTION — IT IS A MEASUREMENT.
#
# The current MCP revision, 2026-07-28, removed the `initialize` handshake:
# servers MUST implement `server/discover`, and every request declares its own
# version in _meta. MEASURED 2026-09-12 by capturing the real wire with
# WALK_MCP_LOG while Claude Code 2.1.258 launched this binary:
#
#   >> {"method":"initialize","params":{"protocolVersion":"2025-11-25", ...
#      "clientInfo":{"name":"claude-code","version":"2.1.258", ...}}, "id":0}
#   >> {"jsonrpc":"2.0","method":"notifications/initialized"}
#   >> {"method":"tools/list","jsonrpc":"2.0","id":1}
#
# No discover probe. No per-request _meta. The host that has to register this
# server speaks the LEGACY era. A server written to the current spec alone would
# not have connected at all, and would have failed with the host looking broken
# rather than the server. So the fixture below is the legacy handshake exactly
# as Claude Code sent it, replayed, plus the modern path the spec now requires.
set -uo pipefail

BIN="${1:?usage: mcp-handshake.sh <path to walk-mcp>}"
EXPECTED_TOOLS="walk_contract walk_grade walk_proof_sheet walk_scan walk_scan_folder walk_segments"
status=0

fail() { echo "::error::$1"; status=1; }

# --- legacy era: the captured Claude Code handshake -------------------------
LEGACY=$(printf '%s\n' \
  '{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.258"}},"jsonrpc":"2.0","id":0}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
  '{"method":"tools/call","params":{"name":"walk_contract","arguments":{}},"jsonrpc":"2.0","id":2}' \
  | "$BIN" 2>/dev/null)

echo "$LEGACY" | grep -q '"protocolVersion":"2025-11-25"' \
  || fail "legacy initialize did not agree the version Claude Code asked for (2025-11-25)"
echo "$LEGACY" | grep -q '"serverInfo"' \
  || fail "legacy initialize result carried no serverInfo"

for t in $EXPECTED_TOOLS; do
  echo "$LEGACY" | grep -q "\"name\":\"$t\"" || fail "tool $t missing from tools/list over the legacy handshake"
done
echo "$LEGACY" | grep -q '"structuredContent"' \
  || fail "walk_contract returned no structuredContent"
echo "$LEGACY" | grep -q "\"walk\":\"$("$BIN" --version)\"" \
  || fail "walk_contract did not report this build's own version"

# --- modern era: discover, per-request _meta, and the version refusal -------
MODERN=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}' \
  | "$BIN" 2>/dev/null)

echo "$MODERN" | grep -q '"supportedVersions"' \
  || fail "server/discover returned no supportedVersions — the current revision says servers MUST implement it"
echo "$MODERN" | grep -q '"resultType":"complete"' \
  || fail "server/discover result was not a complete DiscoverResult"
for t in $EXPECTED_TOOLS; do
  echo "$MODERN" | grep -q "\"name\":\"$t\"" || fail "tool $t missing from tools/list on the modern path"
done

# THE REFUSAL IS REQUIRED. A version gate that has only ever accepted is not a
# gate — the same reason CI requires `walk contract --expect 9.9.9` to fail.
echo "$MODERN" | grep -q '"code":-32022' \
  || fail "an unsupported protocol version was NOT refused with -32022"
echo "$MODERN" | grep -q '"requested":"1900-01-01"' \
  || fail "the version refusal did not name the version that was requested"

# --- 2026-07-28 shape (Claude Code: "missing required resultType") ----------
# MEASURED 2026-10-19. initialize is the LEGACY handshake and must never agree
# to a modern revision; a request declaring the modern version in _meta must get
# resultType on every result, plus ttlMs/cacheScope on the cacheable lists.
M='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
ASKMODERN=$(printf '%s\n' \
  '{"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"jsonrpc":"2.0","id":0}' \
  | "$BIN" 2>/dev/null)
echo "$ASKMODERN" | grep -q '"protocolVersion":"2026-07-28"' \
  && fail "initialize agreed to the modern revision; it is the legacy handshake"
echo "$ASKMODERN" | grep -q '"protocolVersion":"2025-11-25"' \
  || fail "initialize asked for 2026-07-28 did not answer the newest legacy revision"

RT=$(printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{$M}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\",\"params\":{$M}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\",\"params\":{$M}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"prompts/list\",\"params\":{$M}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"walk_contract\",\"arguments\":{},$M}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"server/discover\",\"params\":{$M}}" \
  | "$BIN" 2>/dev/null)
N=$(echo "$RT" | grep -c '"resultType":"complete"' || true)
[ "$N" = "6" ] || fail "modern requests: $N of 6 results carried resultType complete"
for id in 1 3 4 6; do
  echo "$RT" | grep "\"id\":$id[,}]" | grep -q '"ttlMs":' \
    || fail "modern result id $id lacks ttlMs (required on list/discover results)"
  echo "$RT" | grep "\"id\":$id[,}]" | grep -q '"cacheScope":"public"' \
    || fail "modern result id $id lacks cacheScope"
done

# Legacy shape must NOT change: no resultType, no cache hints.
echo "$LEGACY" | grep -q '"resultType"' \
  && fail "a legacy request got resultType; legacy replies must stay byte-compatible"
echo "$LEGACY" | grep -q '"ttlMs"' && fail "a legacy request got ttlMs"

# --- framing: stdout must be nothing but one MCP message per line -----------
BAD=$(echo "$LEGACY$MODERN" | grep -vc '^{' || true)
[ "$BAD" = "0" ] || fail "$BAD line(s) on stdout were not a JSON object — the stdio binding forbids anything else"

# --- an unknown tool must be refused, not guessed at ------------------------
UNKNOWN=$(printf '%s\n' \
  '{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"jsonrpc":"2.0","id":0}' \
  '{"method":"tools/call","params":{"name":"walk_teleport","arguments":{}},"jsonrpc":"2.0","id":1}' \
  | "$BIN" 2>/dev/null)
echo "$UNKNOWN" | grep -q 'Unknown tool: walk_teleport' \
  || fail "an unknown tool name was not refused"

# --- a stale consumer must be refused through the MCP surface too -----------
# The contract exists so a consumer written against an older Walk fails LOUDLY.
# Reaching it through MCP must fail the same way it does on the CLI, or the new
# front door has quietly weakened the control.
STALE=$(printf '%s\n' \
  '{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"jsonrpc":"2.0","id":0}' \
  '{"method":"tools/call","params":{"name":"walk_contract","arguments":{"expect":"0.2.0"}},"jsonrpc":"2.0","id":1}' \
  | "$BIN" 2>/dev/null)
echo "$STALE" | grep -q '"isError":true' \
  || fail "walk_contract accepted a consumer written against 0.2.0 — the version contract is not enforced over MCP"
echo "$STALE" | grep -q 'CONTRACT MISMATCH' \
  || fail "the contract mismatch was not reported as one"

if [ $status -eq 0 ]; then
  echo "walk-mcp handshake checks passed — legacy (the captured Claude Code 2.1.258 exchange) and modern (server/discover + _meta), $(echo $EXPECTED_TOOLS | wc -w | tr -d ' ') tools, refusals required and received"
fi
exit $status
