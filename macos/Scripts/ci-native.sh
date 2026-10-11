#!/usr/bin/env bash
# Native CI, with no linked account, signing certificate or user archive.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
test "$(uname -m)" = arm64 || { echo "Native CI requires an arm64 macOS runner." >&2; exit 1; }
swift --version
xcodebuild -version
python3 - <<'PY'
import re, subprocess
version = tuple(map(int, re.search(r'Swift version (\d+)\.(\d+)', subprocess.check_output(['swift', '--version'], text=True)).groups()))
if version < (6, 2):
    raise SystemExit('Native CI requires Swift 6.2+ (Xcode 26+).')
PY
mkdir -p macos/Build
python3 -m unittest discover -s macos/Scripts/tests
cargo fmt --all --check
cargo clippy --locked --no-default-features --lib -- -D warnings
cargo test --locked --no-default-features --lib
(
    cd macos/Bridge
    cargo fmt --all --check
    cargo clippy --locked --all-targets -- -D warnings
    cargo test --locked --lib
)
macos/Scripts/build-bridge.sh debug
macos/Scripts/check-warnings.sh --disable-sandbox --jobs "${NATIVE_BUILD_JOBS:-2}"
(
    cd macos/Packages/ZapFastKit
    # AppKit fixtures share the process layout scheduler, including the 50k resize stress case.
    swift test --no-parallel --disable-sandbox --force-resolved-versions --jobs "${NATIVE_BUILD_JOBS:-2}"
)
python3 macos/Scripts/license-inventory.py --check
macos/Scripts/build-bridge.sh release
(
    cd macos
    xcodegen generate --quiet
    # The generated Xcode workspace must use the same remote Swift pins.
    resolved=ZapFast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    mkdir -p "$resolved"
    cp Packages/ZapFastKit/Package.resolved "$resolved/Package.resolved"
    xcodebuild -project ZapFast.xcodeproj -scheme ZapFast \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath Build/DerivedData \
        -configuration Release -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build -quiet
)
app="$root/macos/Build/DerivedData/Build/Products/Release/ZapFast.app"
python3 macos/Scripts/check-native-bundle.py "$app"
git diff --exit-code -- Cargo.lock macos/Bridge/Cargo.lock macos/Packages/ZapFastKit/Package.resolved
echo "Native CI passed. Release build is unsigned."
