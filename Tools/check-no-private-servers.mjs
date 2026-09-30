#!/usr/bin/env node
// check-no-private-servers.mjs — a pack runs on strangers' machines, so nothing it
// ships may name or look for a private server. Operator ruling 2026-09-30: "they
// shouldn't be looking for any tailscale or private servers." Scans every text
// file in the repository (not only the files a host loads: a CHANGELOG carried a
// private Control Room URL through agency 1.4.20 because the older check did not
// look there). The same patterns run inside verify-pack.mjs for the packs that
// sync it; this standalone copy is for repos that keep their own verify-pack.
// CANONICAL SOURCE: o-matic-studio/scripts/check-no-private-servers.mjs.
// Usage: node scripts/check-no-private-servers.mjs <repo-root>   Exit 1 on any hit.
import { readFileSync, readdirSync, statSync, lstatSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
const root = process.argv[2] || ".";
const walk = (d) => readdirSync(d).flatMap((f) => {
  const p = join(d, f);
  if (lstatSync(p).isSymbolicLink()) return [];
  return statSync(p).isDirectory() ? walk(p) : [p];
});
const PRIVATE_NAME_SHA256 = new Set(["9274d49c27b7583a60a06420b820077e38c6ad785f6df54b667d42aa9a5b325c", "9731971c9b2dfb957a786ef661835fc1fb1d12886a9c290d1933545aa600c44d"]); // one operator's private host and tailnet names, stored hashed so no shipped file spells them
const namesPrivate = (line) => (line.toLowerCase().match(/[a-z0-9-]{6,}/g) || []).some((w) => PRIVATE_NAME_SHA256.has(createHash("sha256").update(w).digest("hex")));
const PRIVATE = [
  [/https?:\/\/[A-Za-z0-9.-]+\.ts\.net\b/, "a private tailnet address"],
  [/\b[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net\b/, "a private tailnet host"],
  [/\/Users\/[a-z][A-Za-z0-9_-]+\//, "one person's home folder"],
  [/\/Volumes\/NVMe/, "one machine's disk path"],
];
const files = walk(root).filter((f) => !/(^|\/)(\.git|node_modules|\.build|dist)\//.test(f)
  && !/(verify-pack|check-no-private-servers)\.mjs$/.test(f)
  && /\.(md|ya?ml|mjs|js|cjs|ts|py|sh|json|txt|toml|swift)$/.test(f));
let hits = 0;
for (const f of files) {
  readFileSync(f, "utf8").split("\n").forEach((line, k) => {
    if (namesPrivate(line)) { hits++; console.log(`  FAIL  ${f.replace(root, ".")}:${k + 1}: ships one operator's private server or tailnet name`); return; }
    for (const [re, what] of PRIVATE) {
      if (re.test(line)) { hits++; console.log(`  FAIL  ${f.replace(root, ".")}:${k + 1}: ships ${what}`); break; }
    }
  });
}
console.log(hits ? `FAIL: ${hits} private reference(s) in ${files.length} files` : `PASS: no private server, tailnet host or personal path in ${files.length} files`);
process.exit(hits ? 1 : 0);
