#!/usr/bin/env bash
# Prints the system frameworks and libraries the bridge's static library
# needs, for the ZapFastBridge target's linkerSettings in Package.swift.
set -euo pipefail
cd "$(dirname "$0")/../Bridge"
export PATH="$HOME/.cargo/bin:$PATH"
touch src/lib.rs
cargo rustc --quiet --lib --target aarch64-apple-darwin --crate-type staticlib -- --print native-static-libs 2>&1 \
  | sed -n 's/.*native-static-libs: //p' \
  | tr ' ' '\n' \
  | awk '/^-framework$/ { getline f; print ".linkedFramework(\"" f "\")," ; next }
         /^-l/          { l = substr($0, 3); if (l != "System" && l != "c" && l != "m") print ".linkedLibrary(\"" l "\")," }' \
  | sort -u
