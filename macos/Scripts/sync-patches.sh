#!/usr/bin/env bash
# Copies upstream's [patch.crates-io] table into the bridge manifest.
#
# Cargo honours [patch] only in the workspace root, and the bridge is its own
# root, so upstream's egui/winit forks must be repeated there verbatim or the
# bridge would build against different crates than upstream does.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
upstream="$root/Cargo.toml"
bridge="$root/macos/Bridge/Cargo.toml"

block="$(awk '
  /^\[patch\.crates-io\]/ { copying = 1; print; next }
  copying && /^\[/        { exit }
  copying                 { print }
' "$upstream" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$block" ]]; then
  block="# Upstream has no [patch.crates-io] table."
fi

tmp="$(mktemp)"
BLOCK="$block" awk '
  /^# BEGIN UPSTREAM PATCHES/ { print; print ENVIRON["BLOCK"]; skipping = 1; next }
  /^# END UPSTREAM PATCHES/   { skipping = 0 }
  !skipping                   { print }
' "$bridge" > "$tmp"
mv "$tmp" "$bridge"

# Start from upstream's lockfile so the bridge resolves the exact versions
# upstream tested; cargo only adds the bridge's own dependencies on top.
if [[ "${1:-}" == "--lockfile" || ! -f "$root/macos/Bridge/Cargo.lock" ]]; then
  cp "$root/Cargo.lock" "$root/macos/Bridge/Cargo.lock"
  echo "Seeded macos/Bridge/Cargo.lock from upstream."
fi

echo "Synced upstream patches into macos/Bridge/Cargo.toml."
