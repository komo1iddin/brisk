#!/usr/bin/env bash
# Builds the Rust bridge and hands it to Swift:
#
#   macos/Packages/ZapFastKit/Artifacts/ZapFastBridgeFFI.xcframework   (static lib + C header)
#   macos/Packages/ZapFastKit/Sources/ZapFastBridge/Generated/*.swift  (UniFFI wrappers)
#
# Usage: build-bridge.sh [debug|release]   (default: debug, or $CONFIGURATION)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
bridge="$here/Bridge"
kit="$here/Packages/ZapFastKit"
artifacts="$kit/Artifacts"
generated="$kit/Sources/ZapFastBridge/Generated"

configuration="$(echo "${1:-${CONFIGURATION:-debug}}" | tr '[:upper:]' '[:lower:]')"
case "$configuration" in
  debug)   profile="debug";   cargo_flags=() ;;
  release) profile="release"; cargo_flags=(--release) ;;
  *) echo "unknown configuration: $configuration" >&2; exit 64 ;;
esac

# Match the app's deployment target so the static library links cleanly.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
target="aarch64-apple-darwin"

# Xcode build phases run with a minimal PATH.
export PATH="$HOME/.cargo/bin:$PATH"

cd "$bridge"
echo "▸ cargo build ($profile, $target)"
cargo build --lib --target "$target" ${cargo_flags[@]+"${cargo_flags[@]}"}
library="$bridge/target/$target/$profile/libzapfast_bridge.a"

echo "▸ uniffi-bindgen (Swift)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The crate's own uniffi.toml (module names) is picked up from its root.
cargo run --quiet --profile bindgen -p uniffi-bindgen -- generate \
  --library "$library" \
  --language swift \
  --out-dir "$work/out"

mkdir -p "$work/headers" "$generated" "$artifacts"
cp "$work/out/ZapFastBridgeFFI.h" "$work/headers/"
cp "$work/out/ZapFastBridgeFFI.modulemap" "$work/headers/module.modulemap"

# Only rewrite the Swift file when it changed, so Xcode does not recompile
# every dependent module after a Rust-only edit.
if ! cmp -s "$work/out/ZapFastBridge.swift" "$generated/ZapFastBridge.swift"; then
  cp "$work/out/ZapFastBridge.swift" "$generated/ZapFastBridge.swift"
  echo "  updated Generated/ZapFastBridge.swift"
fi

echo "▸ xcframework"
rm -rf "$artifacts/ZapFastBridgeFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$library" \
  -headers "$work/headers" \
  -output "$artifacts/ZapFastBridgeFFI.xcframework" >/dev/null

echo "✓ bridge ready ($profile)"
