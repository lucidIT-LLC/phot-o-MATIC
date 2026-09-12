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

.PHONY: build release test app run clean contract mcp mcp-check install-mcp deprecations verify

build:
	swift build --scratch-path $(SCRATCH)

release:
	swift build -c release --scratch-path $(SCRATCH)

# --build-system native also works and is what CI uses; the scratch path is the
# fix for the cause rather than a way around the symptom.
test:
	swift test --scratch-path $(SCRATCH)

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

install-mcp: release
	mkdir -p $(BINDIR)
	cp $(MCP) $(BINDIR)/walk-mcp
	@echo ""
	@echo "walk-mcp $$($(BINDIR)/walk-mcp --version) installed at $(BINDIR)/walk-mcp"
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
