#!/usr/bin/env bash
# Builds the Rust bridge and hands it to Swift:
#
#   macos/Packages/ZapFastKit/Artifacts/ZapFastBridgeFFI.xcframework   (static lib + C header)
#   macos/Packages/ZapFastKit/Sources/ZapFastBridge/Generated/*.swift  (UniFFI wrappers)
#
# Usage: build-bridge.sh [debug|release]   (default: debug, or $CONFIGURATION)
#
# ZAPFAST_CALLS=1 builds with the `calls` feature: voice and video calls,
# which are in development and left out of public builds.
# ZAPFAST_ARCHS lists the slices, "arm64" by default; a release passes
# "arm64 x86_64" for a universal library (Intel needs
# `rustup target add x86_64-apple-darwin`).
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

case "${ZAPFAST_CALLS:-0}" in
  1|YES|yes|true) cargo_flags+=(--features calls); echo "▸ with calls" ;;
esac

# Match the app's deployment target so the static library links cleanly.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
read -r -a archs <<< "${ZAPFAST_ARCHS:-arm64}"

# Xcode build phases run with a minimal PATH.
export PATH="$HOME/.cargo/bin:$PATH"

cd "$bridge"
slices=()
for arch in "${archs[@]}"; do
  case "$arch" in
    arm64)  target="aarch64-apple-darwin" ;;
    x86_64) target="x86_64-apple-darwin" ;;
    *) echo "unknown architecture: $arch" >&2; exit 64 ;;
  esac
  echo "▸ cargo build ($profile, $target)"
  cargo build --locked --lib --target "$target" ${cargo_flags[@]+"${cargo_flags[@]}"}
  slices+=("$bridge/target/$target/$profile/libzapfast_bridge.a")
done
# One slice is used as it is; several are joined into a universal library.
# The bindings come from the first: every slice exports the same interface.
library="${slices[0]}"
if (( ${#slices[@]} > 1 )); then
  library="$bridge/target/universal/$profile/libzapfast_bridge.a"
  mkdir -p "$(dirname "$library")"
  lipo -create "${slices[@]}" -output "$library"
fi

echo "▸ uniffi-bindgen (Swift)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The crate's own uniffi.toml (module names) is picked up from its root.
cargo run --locked --quiet --profile bindgen -p uniffi-bindgen -- generate \
  --library "${slices[0]}" \
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
framework="$artifacts/ZapFastBridgeFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$library" \
  -headers "$work/headers" \
  -output "$work/ZapFastBridgeFFI.xcframework" >/dev/null

# Put it in place only when it changed. It is a binary target, so a fresh
# copy of the same bytes is still a change to Xcode, and every module that
# depends on the bridge is rebuilt: all of them but ZapFastDesign. That was
# 223 files and half a minute on a build where nothing had been edited.
# `-create-xcframework` is reproducible for the same library, so comparing
# is enough.
if diff -r -q "$work/ZapFastBridgeFFI.xcframework" "$framework" >/dev/null 2>&1; then
  echo "  Artifacts/ZapFastBridgeFFI.xcframework is unchanged"
else
  rm -rf "$framework"
  mv "$work/ZapFastBridgeFFI.xcframework" "$framework"
  echo "  updated Artifacts/ZapFastBridgeFFI.xcframework"
fi

echo "✓ bridge ready ($profile)"
