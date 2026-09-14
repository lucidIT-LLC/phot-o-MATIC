# Walk — build and test.
#
# WHY THIS FILE EXISTS, and it is not a preference for make.
#
# MEASURED 2026-09-12: this repository lives in ~/Documents, which is an iCloud
# Drive File Provider domain. The File Provider stamps com.apple.FinderInfo and
# com.apple.fileprovider.fpfs#P onto bundle directories, and codesign refuses to
# sign a bundle carrying them — "resource fork, Finder information, or similar
# detritus not allowed". That single cause blocks BOTH `swift test` under the
# Xcode build system and `xcodebuild` of the app, and the 0.2.0 changelog
# recorded only the first of the two and named the build system rather than the
# build location.
#
# Proven both directions:
#   swift test                          -> CodeSign fails on WalkKitTests.xctest
#   swift test --scratch-path <outside> -> 30 tests pass
#   xcodebuild (products in ./App/Build)   -> CodeSign fails on Walk.app
#   xcodebuild (products outside ~/Documents) -> BUILD SUCCEEDED
#
# CI is unaffected — a GitHub runner's checkout is not in a File Provider
# domain — so CI uses the plain commands and this file is for this machine.

SCRATCH := $(HOME)/Library/Developer/Xcode/DerivedData/Walk-spm

.PHONY: build release test app run clean contract mcp mcp-check install install-cli install-mcp install-check stage-plugin plugin-check gate gate-check gate-home deprecations verify

build:
	swift build --scratch-path $(SCRATCH)

release:
	swift build -c release --scratch-path $(SCRATCH)

# --build-system native also works and is what CI uses; the scratch path is the
# fix for the cause rather than a way around the symptom.
#
# --no-parallel IS LOAD-BEARING. MEASURED 2026-09-13.
#
# Run in parallel, this suite deadlocks. Sampled: TWELVE tests simultaneously
# blocked in AVAssetReaderOutput.Provider.next() -> _pthread_cond_wait, every
# one on com.apple.root.default-qos.cooperative. hw.ncpu is twelve. That is the
# entire Swift Concurrency cooperative pool parked at once -- Apple's async
# provider blocks a cooperative thread underneath an await, and with enough
# concurrent video tests there is no thread left to resume any of them.
#
# Proven both directions on this machine:
#   swift test                 -> wedged at 0.0% CPU, 29 min, no output
#   swift test --no-parallel   -> 138 tests pass in 251 s
#   one video test alone       -> passes in 2.2 s
#
# THE CAUSE IS NOW REMOVED AND --no-parallel IS GONE WITH IT (task #764,
# 2026-09-13). VideoReader.Pass.next() runs under a ReadExecutor task-executor
# preference (SE-0417), so the blocking decode lands on a Dispatch thread that
# is allowed to block instead of on a cooperative one. MEASURED after the change:
#   swift test (PARALLEL)      -> 142 tests pass in 215 s
# and the new starvation test, run against a build with the preference removed,
# parked twelve passes and was aborted by the watchdog at 45 s. --no-parallel
# was only ever a fix for the test process; walk-mcp had the same exposure.
#
# WALK_TEST_WATCHDOG_SECONDS IS STILL HERE, AND IT STAYS. It is the detector for
# the day the preference is dropped, a new read path is added that does not go
# through Pass.next(), or a future SDK blocks somewhere else. If the deadlock
# returns -- it aborts the process
# with a diagnostic and a nonzero status instead of hanging. THAT DISTINCTION
# IS THE WHOLE POINT: a hang writes zero bytes and reads exactly like a job
# that never started, which is how this went unexplained for a day.
#
# The limit is a gap BETWEEN DECODED FRAMES while a read pass is open, not a
# test duration. The slowest legitimate test here runs 213 s and beats
# continuously throughout.
test:
	WALK_TEST_WATCHDOG_SECONDS=120 swift test --scratch-path $(SCRATCH)

contract: release
	$(SCRATCH)/release/walk contract

# --- the MCP front door -----------------------------------------------------
#
# Decision #507: this is the primary way in. `mcp` just builds and names the
# surface; `mcp-check` replays both protocol eras against the built binary,
# including the legacy handshake captured off the wire from Claude Code 2.1.258.

MCP := $(SCRATCH)/release/walk-mcp

mcp: release
	$(MCP) --selftest

mcp-check: release
	./.github/mcp-handshake.sh $(MCP)
	./.github/check-tool-docs.py $(MCP)

# REGISTRATION IS THE OPERATOR'S TO RUN, not this Makefile's to do behind him.
# `claude mcp add --scope user` writes to ~/.claude.json, which is host
# configuration; a build target is not the place for that. This copies the
# binary somewhere stable — the release path above is a build directory and will
# be wiped by `make clean` — and prints the one command to run.
#
# Verified on this host 2026-09-12 WITHOUT persisting anything, using
#   claude --strict-mcp-config --mcp-config <file>
# and WALK_MCP_LOG to capture the exchange. See mcp-handshake.sh.
BINDIR := $(HOME)/.local/bin

# --- staging the front doors ------------------------------------------------
#
# TASK #729: THE CLI HAD NO INSTALL TARGET AT ALL, AND THE ABSENCE IS THE DEFECT.
#
# MEASURED 2026-09-12: `$(BINDIR)/walk --version` reported 0.3.0 while
# `$(BINDIR)/walk-mcp --version` reported 0.5.0, on this host, from this tree.
# There was an `install-mcp` target and nothing for the CLI, so the front door
# with an install path stayed current and the one without drifted through two
# releases. `make clean` removes the release directory the stale binary was
# copied from, so nothing on the box could say what build it was.
#
# It was not cosmetic. `walk contract --expect 0.5.0` exited 1 (measured), so
# Andy's skill section 8.5 version gate read as FAILING — the gate was right,
# it was reporting a real drift, and there was no path to fix what it found. And
# `walk contract` listed ZERO `coach.*` capabilities (measured) while walk-mcp
# told the same host they were declared: one host, two front doors, two
# contracts.
#
# THE CHECK IS ONE SCRIPT BOTH TARGETS CALL, not a check per target. #740 gave
# `install-mcp` a good check — capture the version, fail on blank, fail on
# disagreement with Sources/WalkKit/Version.swift — and that check being in ONE
# target is what let the other one drift. A copied check can diverge; the
# diverging front door IS #729. `.github/stage-binary.sh` now holds it, adds the
# two cases the inline version could not express (a missing build, an unreadable
# Version.swift) and PROVES IT CAN FAIL under `--selftest`, the same way
# check-doctrine.py does.
#
# REGISTRATION IS STILL THE OPERATOR'S TO RUN, not this Makefile's to do behind
# him — see the note under install-mcp.
CLI := $(SCRATCH)/release/walk

# BOTH DOORS, ONE COMMAND, and that is the structural half of the fix. Two
# separate install targets would leave "did you do the other one?" to memory,
# which is how 0.3.0 and 0.5.0 came to be installed side by side.
install: install-cli install-mcp
	@echo ""
	@echo "both front doors staged from this tree and each verified against Walk.version"

install-cli: release
	./.github/stage-binary.sh walk $(CLI) $(BINDIR)
	@set -e; \
	 declared=$$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/WalkKit/Version.swift); \
	 echo ""; \
	 echo "Proving the gate a consumer actually reads — Andy's skill section 8.5"; \
	 echo "runs exactly this, and this is the command that exited 1 under #729:"; \
	 echo "  walk contract --expect $$declared"; \
	 $(BINDIR)/walk contract --expect $$declared
	@echo ""
	@echo "A LOWERED --expect IS NOT A FIX. #729 forbids it in terms: the gate"
	@echo "reporting a mismatch is the gate working. Stage the current build."

# Can the install check fail? Run before trusting it to pass.
install-check:
	./.github/stage-binary.sh --selftest

install-mcp: release
	./.github/stage-binary.sh walk-mcp $(MCP) $(BINDIR)
	@echo ""
	@echo "A REGISTERED SERVER IS ALREADY RUNNING FROM THE OLD BINARY."
	@echo "  A stdio MCP server is spawned once at session start, so this file does not"
	@echo "  take effect until the host restarts. Until then walk_contract correctly"
	@echo "  reports the OLD version — that is the running process answering honestly,"
	@echo "  not a failed install. #740: the operator learned he was still on 0.4.1"
	@echo "  exactly this way."
	@echo ""
	@echo "Register it with Claude Code:"
	@echo "  claude mcp add --scope user --transport stdio walk $(BINDIR)/walk-mcp"
	@echo ""
	@echo "Then confirm:  claude mcp get walk"
	@echo "Trace the wire: WALK_MCP_LOG=/tmp/walk-wire.log in the server's env"

# ---------------------------------------------------------------------------
# THE PLUGIN PAYLOAD — decision #534.
#
# Walk ships as an o-MATIC plugin installed from the GitHub marketplace, which
# means the REPOSITORY ROOT IS THE PLUGIN ROOT: .mcp.json, .claude-plugin/,
# .codex-plugin/, skills/ and bin/ are the payload a host clones, and bin/walk-mcp
# is a committed build artifact rather than something the host compiles.
#
# THIS TARGET CALLS .github/stage-binary.sh AND DOES NOT REIMPLEMENT ITS CHECK.
# That script's own header states the rationale and it applies verbatim here:
# the version check "existed in one place, so 'both front doors are checked'
# depended on somebody remembering to copy it. A copied check is a check that
# can diverge, and the diverging front door is the exact defect #729 filed."
# Staging the plugin is now a THIRD front door. A hand-rolled `cp` here would
# recreate #729 on the one surface that reaches customers, where a stale binary
# is not a developer's annoyance but a shipped lie about what the plugin is.
#
# So: same script, different bindir. The plugin binary cannot silently disagree
# with Sources/WalkKit/Version.swift, because the same code refuses to stage it.
PLUGINBIN := $(CURDIR)/bin

stage-plugin: release
	./.github/stage-binary.sh walk-mcp $(MCP) $(PLUGINBIN)
	@# Gatekeeper quarantine on a committed binary is the failure that looks
	@# like a crash instead of a refusal. Clear it here, at the moment the file
	@# is produced, rather than asking every installer to know about it.
	@xattr -c $(PLUGINBIN)/walk-mcp 2>/dev/null || true
	@echo ""
	@echo "plugin payload staged. Verifying what a host would actually get:"
	@$(MAKE) --no-print-directory plugin-check

# Can a host run what is in bin/? Asked, not assumed.
#
# `walk-mcp --help` HANGS FOREVER ON STDIN (measured) — it is a stdio server and
# an empty stdin is a session that never ends — so nothing here may invoke it
# without closing stdin. `--version` returns and exits; that is the probe.
plugin-check:
	@set -e; \
	fail=0; \
	declared="$$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/WalkKit/Version.swift)"; \
	for f in .mcp.json .claude-plugin/plugin.json .codex-plugin/plugin.json \
	         bin/omatic-walk-launch.sh bin/omatic-walk-degraded-server.sh bin/walk-mcp; do \
		[ -e "$$f" ] || { echo "plugin-check FAILED: $$f is missing from the payload" >&2; fail=1; }; \
	done; \
	for f in bin/omatic-walk-launch.sh bin/omatic-walk-degraded-server.sh bin/walk-mcp; do \
		[ -x "$$f" ] || { echo "plugin-check FAILED: $$f is not executable; a host will not be able to spawn it" >&2; fail=1; }; \
	done; \
	for f in .mcp.json .claude-plugin/plugin.json .codex-plugin/plugin.json; do \
		python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$$f" || \
			{ echo "plugin-check FAILED: $$f is not valid JSON" >&2; fail=1; }; \
	done; \
	:; \
	: 'The documented variable is CLAUDE_PLUGIN_ROOT. The plugins reference states'; \
	: 'it in terms — "Exact variable names: CLAUDE_PLUGIN_ROOT (not PLUGIN_ROOT)" —'; \
	: 'and a bare $${PLUGIN_ROOT} does not expand, so the host spawns /bin/sh on a'; \
	: 'path beginning with a literal dollar sign and the plugin has no tools. That'; \
	: 'reads as "not configured". This is the check that keeps it from being ours.'; \
	if grep -q '\$${PLUGIN_ROOT}' .mcp.json .claude-plugin/plugin.json .codex-plugin/plugin.json 2>/dev/null; then \
		echo "plugin-check FAILED: a manifest uses \$${PLUGIN_ROOT}, which is not a" >&2; \
		echo "  documented variable and does not expand. Use \$${CLAUDE_PLUGIN_ROOT}." >&2; \
		fail=1; \
	fi; \
	grep -q 'CLAUDE_PLUGIN_ROOT' .mcp.json || \
		{ echo "plugin-check FAILED: .mcp.json does not reference \$${CLAUDE_PLUGIN_ROOT}; the launcher path cannot resolve" >&2; fail=1; }; \
	: 'One version, not two that can diverge — the whole lesson of #729.'; \
	for m in .claude-plugin/plugin.json .codex-plugin/plugin.json; do \
		mv="$$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$$m")"; \
		[ "$$mv" = "$$declared" ] || { echo "plugin-check FAILED: $$m declares $$mv, the source tree declares $$declared" >&2; fail=1; }; \
	done; \
	if [ -e bin/walk-mcp ]; then \
		: 'stdin is closed so a stdio server cannot park on it.'; \
		iv="$$(./bin/walk-mcp --version < /dev/null 2>/dev/null || true)"; \
		[ "$$iv" = "$$declared" ] || { echo "plugin-check FAILED: bin/walk-mcp reports '$$iv', tree declares '$$declared'" >&2; fail=1; }; \
		file bin/walk-mcp | grep -q 'arm64' || { echo "plugin-check FAILED: bin/walk-mcp is not an arm64 Mach-O" >&2; fail=1; }; \
		if xattr bin/walk-mcp 2>/dev/null | grep -q 'com.apple.quarantine'; then \
			echo "plugin-check FAILED: bin/walk-mcp carries com.apple.quarantine and macOS will refuse to run it" >&2; fail=1; \
		fi; \
	fi; \
	: 'The three skills are payload, not decoration — #534 ships them inside.'; \
	for s in media-triage coreml-vision creator-studio; do \
		[ -f "skills/$$s/SKILL.md" ] || { echo "plugin-check FAILED: skills/$$s/SKILL.md is missing" >&2; fail=1; }; \
	done; \
	if [ "$$fail" -ne 0 ]; then echo "" >&2; echo "plugin payload is NOT shippable." >&2; exit 1; fi; \
	echo "  plugin payload OK — walk-mcp $$declared, arm64, unquarantined, manifests agree"

# Every deprecation in the build, against the reasoned allowlist. Fails on a new
# one AND on a stale entry. See .github/deprecations-allowed.txt.
#
# A SEPARATE, WIPED SCRATCH PATH, AND THAT IS THE WHOLE POINT OF THE TARGET.
# The first version of this reused $(SCRATCH), so the build was incremental, the
# compiler re-emitted nothing, and the inventory came back empty — which made the
# allowlist look stale and failed the build for the wrong reason. CI is immune
# because a fresh checkout has nothing to be incremental against; a developer's
# machine is not, and an unbuilt source file emits no diagnostic about itself.
# This is the same trap the CI workflow already comments on at the Build step:
# the log only says what the compiler was asked to compile.
DEPSCRATCH := $(SCRATCH)-deps

deprecations:
	rm -rf $(DEPSCRATCH)
	swift build -c release --scratch-path $(DEPSCRATCH) 2>&1 | tee /tmp/walk-build.log > /dev/null
	./.github/check-deprecations.sh /tmp/walk-build.log

# --- the #254 brand gate over the shipped criteria set (task #772) ----------
#
# Brandy's gate was design_verified: a verdict nothing could refuse with. Smith
# built the executable half and named the remaining gap himself — it stays
# design_verified "until it lands in CI and something red actually blocks a
# release." `gate-check` is the proof it can fail; `gate` is the gate.
#
# RUN gate-check BEFORE TRUSTING gate, the same discipline as install-check.
gate-check:
	./Tools/brand-gate/check-single-home.sh --selftest
	python3 Tools/brand-gate/run_eval.py

gate: gate-home
	python3 Tools/brand-gate/brand_gate_254.py criteria/walk-criteria.json \
		--waivers Tools/brand-gate/waivers.txt

# ONE HOME, ENFORCED. The check existed in two places and had already diverged;
# see the header of the script for what the stale twin was doing.
gate-home:
	./Tools/brand-gate/check-single-home.sh

# Everything CI does that can be done locally, in CI's order.
verify: deprecations test mcp-check contract gate-check plugin-check
	@echo ""
	@echo "local verify complete — CI additionally builds the app bundle and,"
	@echo "on a tag, asserts the tag equals Walk.version"

# SYMROOT/OBJROOT on the COMMAND LINE, not in the project file. Measured: set
# in the project, xcodebuild refuses with "Packages are not supported when
# using legacy build locations" and the app depends on the WalkKit package.
# Passed on the command line the same values resolve packages and sign cleanly.
# A WorkspaceSettings.xcsettings with BuildLocationStyle = UseAppPreferences was
# also tried and did NOT move xcodebuild's products, so it was removed rather
# than committed with a comment claiming something it does not do.
APPBUILD := $(HOME)/Library/Developer/Xcode/DerivedData/Walk-app

app:
	xcodebuild -project App/Walk.xcodeproj -scheme Walk -configuration Release \
	  SYMROOT=$(APPBUILD)/Products OBJROOT=$(APPBUILD)/Intermediates build

run: app
	open "$(APPBUILD)/Products/Release/Walk.app"

clean:
	rm -rf $(SCRATCH) $(SCRATCH)-deps $(APPBUILD) .build App/Build build
