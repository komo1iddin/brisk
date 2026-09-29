# Entry points for the macOS app. Run from macos/.
#
#   make            bridge + project + build (Debug)
#   make run        build and open the app
#   make test       unit tests of ZapFastKit
#   make release    optimised build
#   make sync       merge upstream and re-sync the bridge

CONFIG      ?= Debug
DERIVED     := Build/DerivedData
APP         := $(DERIVED)/Build/Products/$(CONFIG)/ZapFast.app
XCODEBUILD  := xcodebuild -project ZapFast.xcodeproj -scheme ZapFast -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED)

.PHONY: all bridge project build run test release sync clean

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

sync:
	./Scripts/sync-upstream.sh

clean:
	rm -rf Build ZapFast.xcodeproj Packages/ZapFastKit/Artifacts Packages/ZapFastKit/Sources/ZapFastBridge/Generated
	cd Bridge && cargo clean
