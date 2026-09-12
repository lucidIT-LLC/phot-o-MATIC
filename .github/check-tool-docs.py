#!/usr/bin/env python3
"""Every MCP tool parameter must appear in the README's tool block, and the
block must not name a parameter no tool has.

WHY THIS IS A CONTROL AND NOT A TIDINESS PREFERENCE. This repository exists
around one defect class: prose describing a mechanism, the mechanism changing,
and nothing noticing. A retired KB number cited as live authority. A rule naming
a connection that had been renamed. `ingest.dump` read as a flat denial while the
app walked folders. A README documenting `--frames` after it became `from_frame`
is the same defect with a smaller blast radius, and it is the one a consumer
reads first.

The comparison is loose in one direction on purpose: it checks that every
parameter NAME is mentioned somewhere in the block, not that the block is
formatted a particular way. A check that dictates prose style gets switched off;
a check that only verifies names survives.

usage: check-tool-docs.py <path to walk-mcp>
"""
import json
import os
import re
import subprocess
import sys

# Prose connectives that legitimately appear inside the block.
PROSE = {"every", "option", "neutral", "dramatic"}

HANDSHAKE = [
    {"jsonrpc": "2.0", "id": 0, "method": "initialize",
     "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "check-tool-docs", "version": "1"}}},
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-tool-docs.py <path to walk-mcp>")
        return 2
    binary = sys.argv[1]
    readme = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "README.md")

    stdin = "".join(json.dumps(m) + "\n" for m in HANDSHAKE)
    run = subprocess.run([binary], input=stdin, capture_output=True, text=True)

    tools = None
    for line in run.stdout.splitlines():
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("id") == 1 and "result" in message:
            tools = message["result"]["tools"]
    if not tools:
        print("::error::tools/list returned nothing")
        return 1

    text = open(readme).read()
    block = re.search(r"### The MCP tools\n\n```\n(.*?)```", text, re.S)
    if not block:
        print('::error::README has no fenced "### The MCP tools" block to check against')
        return 1
    words = set(re.findall(r"[a-z_][a-z_0-9]*", block.group(1)))

    status = 0
    parameters = 0
    for tool in tools:
        name = tool["name"]
        if name not in words:
            print("::error::tool %s is not named in the README tool block" % name)
            status = 1
        for key in sorted(tool["inputSchema"].get("properties", {})):
            parameters += 1
            if key not in words:
                print("::error::%s takes '%s' and the README tool block does not mention it"
                      % (name, key))
                status = 1

    live = {k for t in tools for k in t["inputSchema"].get("properties", {})}
    live |= {t["name"] for t in tools}
    for word in sorted(words - live - PROSE):
        print("::error::the README tool block names '%s', which no tool takes" % word)
        status = 1

    if status == 0:
        print("tool docs match the live schema: %d tools, %d parameters, "
              "none undocumented and none invented" % (len(tools), parameters))
    return status


if __name__ == "__main__":
    sys.exit(main())
