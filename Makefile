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

.PHONY: build release test app run clean contract

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
	rm -rf $(SCRATCH) $(APPBUILD) .build App/Build build
