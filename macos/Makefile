# Entry points for the macOS app. Run from macos/.
#
#   make            bridge + project + build (Debug)
#   make run        build and open the app
#   make test       unit tests of ZapFastKit
#   make release    optimised build
#   make sync       merge upstream and re-sync the bridge
#   make check      no warnings in ZapFastKit, then its tests
#
# CALLS=1 (e.g. `make run CALLS=1`) builds with voice and video calls, which
# are in development and left out of public builds.

CONFIG      ?= Debug
CALLS       ?= 0
# Read by Scripts/build-bridge.sh, here and in the scheme's pre-action.
export ZAPFAST_CALLS := $(CALLS)
DERIVED     := Build/DerivedData
APP         := $(DERIVED)/Build/Products/$(CONFIG)/ZapFast.app
# The bridge is built for Apple silicon only (Scripts/build-bridge.sh), so the
# app is too; Release otherwise builds an Intel slice that cannot link.
XCODEBUILD  := xcodebuild -project ZapFast.xcodeproj -scheme ZapFast -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) ARCHS=arm64

.PHONY: all bridge project build run test release sync footprint clean check ci

all: build

bridge:
	./Scripts/build-bridge.sh $(CONFIG)

project:
	xcodegen generate --quiet

build: bridge project
	$(XCODEBUILD) -configuration $(CONFIG) build -quiet

run: build
	open "$(APP)"

test: bridge
	cd Packages/ZapFastKit && xcodebuild test -scheme ZapFastKit -destination 'platform=macOS,arch=arm64' -derivedDataPath ../../$(DERIVED) -quiet

release:
	$(MAKE) build CONFIG=Release

# The same engine, bridge, native tests and unsigned Release checks as CI.
ci:
	bash Scripts/ci-native.sh

sync:
	./Scripts/sync-upstream.sh

# What this fork has done to upstream's tree, and so where a merge can hurt.
footprint:
	./Scripts/upstream-footprint.sh

# Before merging: no warnings in ZapFastKit's own sources (some Swift 6
# isolation errors are only warnings, and crash at run time), then the tests.
check: bridge
	./Scripts/check-warnings.sh
	cd Packages/ZapFastKit && swift test --no-parallel

clean:
	rm -rf Build ZapFast.xcodeproj Packages/ZapFastKit/Artifacts Packages/ZapFastKit/Sources/ZapFastBridge/Generated
	cd Bridge && cargo clean
