#!/usr/bin/env node
// spirit-gate-check.mjs -- rule #350 (decision #587), task #881.
//
// Every plugin released from the lucidIT-LLC o-MATIC marketplace repos
// (agency, firm, studio, supply, phot-o-MATIC) is O-Matic-branded by
// definition and is always gated by the Spirit Gate: it must carry a
// human-reviewed PASS verdict, recorded in factory.spirit_gate_verdicts on
// the o-matic factory database, for the EXACT bytes being released. This
// script is that check, run as CI, before the release (a push to `main`,
// which is what the marketplace consumes) ships.
//
// This is the plugin-side half of task #881; the web-publish half lives in
// o-matic-server's factory_web_publish (src/omatic_embedder/mcp_server.py).
// Both call the same database function, `factory.fn_spirit_gate_cleared`,
// which is proven live 6/6 by `factory.fn_prove_spirit_gate()` (Data,
// 2026-09-23) -- this script's job is only to call it correctly and fail
// the job when it refuses, never to judge anything itself.
//
// WHAT IS GATED: every top-level plugin directory in this marketplace (one
// with a .claude-plugin/plugin.json) -- unconditionally. A plugin.json
// "brand_sensitive": true flag can only ADD a gate elsewhere; its absence
// here never removes this one, because membership in this repo is what
// makes it O-Matic-branded, not that flag.
//
// IDENTITY: artifact_ref = 'plugin:<marketplace>/<plugin>' (marketplace is
// .claude-plugin/marketplace.json's own "name"). artifact_sha256 is computed
// the same way o-matic-server computes a web release's checksum
// (web_publish.compute_release_manifest): one `sha256(file)  relpath` line
// per file TRACKED BY GIT under that plugin directory, sorted by path in
// byte order, newline-joined, then that manifest text is itself sha256'd.
// Using `git ls-files` (not a raw directory walk) means the checksum is
// exactly "what ships" -- untracked scratch files in a plugin author's
// working tree never change it, and this is the same anchor task #774 asked
// every gate verdict to carry: a content hash, never a byte count or
// version string, so an edit that swaps content of the same length still
// requires a fresh review.
//
// Usage: node scripts/spirit-gate-check.mjs <marketplace-root>
// Env:   OMATIC_MCP_URL   (default https://stallion.blue-triggerfish.ts.net:8439/mcp)
//        OMATIC_MCP_TOKEN (required -- a repo secret, never printed or logged)
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const root = process.argv[2];
if (!root) { console.error("usage: spirit-gate-check.mjs <marketplace-root>"); process.exit(2); }

const MCP_URL = process.env.OMATIC_MCP_URL || "https://stallion.blue-triggerfish.ts.net:8439/mcp";
const TOKEN = process.env.OMATIC_MCP_TOKEN;

let fails = 0;
const FAIL = (m) => { console.log(`  FAIL  ${m}`); fails++; };
const OK = (m) => { console.log(`  ok    ${m}`); };

if (!TOKEN) {
  FAIL("OMATIC_MCP_TOKEN is not set -- cannot reach the o-MATIC Server to check the " +
       "Spirit Gate (rule #350). Add it as a repository secret; see docs/DEPLOY.md in " +
       "o-matic-server for how the token is minted.");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// A minimal MCP Streamable HTTP client -- just enough to call `startup`
// (required by the task #653 session-startup gate before `factory_query` is
// callable at all) and `factory_query`. No SDK dependency: this repo ships
// no MCP server itself and should not need to install a client for one CI
// check.
// ---------------------------------------------------------------------------

let sessionId = null;

async function rpc(method, params) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params });
  const headers = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "Authorization": `Bearer ${TOKEN}`,
  };
  if (sessionId) headers["Mcp-Session-Id"] = sessionId;
  const res = await fetch(MCP_URL, { method: "POST", headers, body });
  const sid = res.headers.get("Mcp-Session-Id");
  if (sid) sessionId = sid;
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); }
  catch (e) { throw new Error(`${method}: non-JSON response (HTTP ${res.status}): ${text.slice(0, 300)}`); }
  if (json.error) throw new Error(`${method}: ${json.error.code} ${json.error.message}`);
  return json.result;
}

async function callTool(name, args) {
  const result = await rpc("tools/call", { name, arguments: args });
  if (result.isError) throw new Error(`${name} tool error: ${JSON.stringify(result.structuredContent ?? result.content)}`);
  return result.structuredContent;
}

async function connectAndFindOmaticConnection() {
  await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "spirit-gate-check", version: "1.0.0" },
  });
  // Connection names are operator-facing strings and must be read off the
  // wire, never hardcoded here (the same rule this factory's own CLAUDE.md
  // states, after being burned twice by a hardcoded spelling going stale).
  // Match on the GRANTED connection whose own database is 'o-matic', not on
  // a display name.
  const discover = await callTool("startup", {});
  const granted = discover.granted || [];
  const conn = granted.find(g => g.database === "o-matic");
  if (!conn) {
    throw new Error("the o-matic administration connection is not granted to this " +
                     "CI credential (database == 'o-matic' not found in startup.granted). " +
                     "Report this as a grant gap, do not try alternate spellings.");
  }
  // The task #653 session-startup gate only records a session as "started"
  // once `startup` runs against a NAMED connection (the discovery call above
  // returns `needs_connection: true` and records nothing when more than one
  // connection is granted, which this CI credential's grant set is). This
  // second call is what factory_query's gate actually checks for.
  await callTool("startup", { connection: conn.name });
  return conn.name;
}

async function fnSpiritGateCleared(connection, artifactRef, sha256) {
  // artifactRef/sha256 are both validated by the caller against a strict
  // allowlist before this is ever built into SQL text -- factory_query takes
  // one raw SQL statement with no parameter binding, so the safety property
  // here is the same one web_publish.py documents for its own inputs:
  // validate BEFORE building anything, never escape after.
  const sql = `SELECT * FROM factory.fn_spirit_gate_cleared('${artifactRef}', '${sha256}', 'omatic')`;
  const out = await callTool("factory_query", { connection, sql, limit: 1 });
  const row = (out.rows || [])[0];
  if (!row) throw new Error(`fn_spirit_gate_cleared returned no row for ${artifactRef}`);
  return row; // {cleared, verdict, reason, verdict_id, reviewer, reviewed_at}
}

// ---------------------------------------------------------------------------
// Content-hash manifest -- mirrors web_publish.compute_release_manifest
// exactly in shape (see the file header above).
// ---------------------------------------------------------------------------

const ARTIFACT_REF_RE = /^plugin:[a-z0-9](?:[a-z0-9._-]{0,63})\/[a-z0-9](?:[a-z0-9._-]{0,63})$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

function gitTrackedFiles(pluginDir) {
  const out = execFileSync("git", ["ls-files", "-z", "--", pluginDir], { cwd: root });
  return out.toString("utf8").split("\0").filter(Boolean);
}

function computeManifestSha256(pluginDir) {
  const files = gitTrackedFiles(pluginDir);
  const lines = files.map(relFromRoot => {
    const abs = join(root, relFromRoot);
    const data = readFileSync(abs);
    const sha = createHash("sha256").update(data).digest("hex");
    return `${sha}  ${relFromRoot}`;
  });
  lines.sort((a, b) => {
    const pa = a.split("  ", 2)[1], pb = b.split("  ", 2)[1];
    return pa < pb ? -1 : pa > pb ? 1 : 0;
  });
  const manifestText = lines.length ? lines.join("\n") + "\n" : "";
  return createHash("sha256").update(manifestText, "utf8").digest("hex");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const mkPath = join(root, ".claude-plugin", "marketplace.json");
  if (!existsSync(mkPath)) { FAIL("marketplace.json missing -- verify-pack.mjs already failed this"); return; }
  const marketplace = JSON.parse(readFileSync(mkPath, "utf8")).name;
  if (!marketplace) { FAIL("marketplace.json has no name"); return; }

  const pluginDirs = readdirSync(root).filter(d => {
    if (!statSync(join(root, d)).isDirectory() || d.startsWith(".")) return false;
    return existsSync(join(root, d, ".claude-plugin", "plugin.json"));
  });
  if (!pluginDirs.length) { FAIL("no plugin directories found under this marketplace root"); return; }

  console.log(`\n=== Spirit Gate (rule #350) check: ${marketplace} ===\n`);

  let connection;
  try {
    connection = await connectAndFindOmaticConnection();
  } catch (e) {
    FAIL(`could not reach the o-MATIC Server: ${e.message}`);
    return;
  }

  for (const dir of pluginDirs) {
    const artifactRef = `plugin:${marketplace}/${dir}`;
    if (!ARTIFACT_REF_RE.test(artifactRef)) {
      FAIL(`${artifactRef}: does not match the safe artifact_ref pattern; refusing to build SQL from it`);
      continue;
    }
    let sha256;
    try {
      sha256 = computeManifestSha256(dir);
    } catch (e) {
      FAIL(`${dir}: could not compute the release-manifest checksum: ${e.message}`);
      continue;
    }
    if (!SHA256_RE.test(sha256)) { FAIL(`${dir}: computed checksum is not 64-hex; refusing to proceed`); continue; }

    let row;
    try {
      row = await fnSpiritGateCleared(connection, artifactRef, sha256);
    } catch (e) {
      FAIL(`${artifactRef}: Spirit Gate check failed: ${e.message}`);
      continue;
    }
    if (row.cleared) {
      OK(`${artifactRef} @ ${sha256.slice(0, 12)}...: cleared (verdict ${row.verdict_id}, ${row.reviewer})`);
    } else {
      FAIL(`${artifactRef} @ ${sha256.slice(0, 12)}...: ${row.reason}`);
    }
  }

  console.log(`\n${fails === 0 ? "PASS" : "FAIL"}: ${fails} failure(s)\n`);
}

main().then(() => process.exit(fails === 0 ? 0 : 1))
  .catch(e => { console.error(`spirit-gate-check.mjs crashed: ${e.stack || e}`); process.exit(1); });
