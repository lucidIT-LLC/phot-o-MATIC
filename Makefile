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

.PHONY: build release test app run clean contract mcp mcp-check install install-cli install-mcp install-check deprecations verify

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
# WALK_TEST_WATCHDOG_SECONDS is the backstop, not the fix. If the deadlock ever
# returns -- someone drops --no-parallel, CI runs the plain command, or a new
# test opens enough passes to starve the pool anyway -- it aborts the process
# with a diagnostic and a nonzero status instead of hanging. THAT DISTINCTION
# IS THE WHOLE POINT: a hang writes zero bytes and reads exactly like a job
# that never started, which is how this went unexplained for a day.
#
# The limit is a gap BETWEEN DECODED FRAMES while a read pass is open, not a
# test duration. The slowest legitimate test here runs 213 s and beats
# continuously throughout.
test:
	WALK_TEST_WATCHDOG_SECONDS=120 swift test --scratch-path $(SCRATCH) --no-parallel

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
# Pixel's skill section 8.5 version gate read as FAILING — the gate was right,
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
	 echo "Proving the gate a consumer actually reads — Pixel's skill section 8.5"; \
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

# Everything CI does that can be done locally, in CI's order.
verify: deprecations test mcp-check contract
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
