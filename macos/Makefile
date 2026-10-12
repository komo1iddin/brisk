# Entry points for the macOS app. Run from macos/.
#
#   make            bridge + project + build (Debug)
#   make run        build and open the app
#   make test       unit tests of ZapFastKit
#   make release    optimised universal build (Apple silicon and Intel)
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
# The slices to build: Apple silicon for everyday work, and Intel too for a
# release. Scripts/build-bridge.sh builds the bridge for the same ones, here
# and in the scheme's pre-action, so they always link.
ARCHS       ?= arm64
export ZAPFAST_ARCHS := $(ARCHS)
XCODEBUILD  := xcodebuild -project ZapFast.xcodeproj -scheme ZapFast -destination 'generic/platform=macOS' -derivedDataPath $(DERIVED) ARCHS="$(ARCHS)" ONLY_ACTIVE_ARCH=NO

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
	$(MAKE) build CONFIG=Release ARCHS="arm64 x86_64"

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
