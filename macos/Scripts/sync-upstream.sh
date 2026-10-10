#!/usr/bin/env bash
# Brings in upstream ZapFast and checks the bridge still fits it.
#
#   1. fetch and merge upstream/main. Files only this fork has cannot
#      conflict, wherever they live; the files it has edited of upstream's
#      can, and `upstream-footprint.sh` lists them before the merge starts;
#   2. copy upstream's [patch.crates-io] and lockfile into the bridge;
#   3. build the bridge: a compile error here names exactly which upstream
#      type, field or event changed and needs a decision in macos/Bridge.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi

before="$(git rev-parse --short HEAD)"
git fetch upstream

# Where this merge can hurt, before it does.
"$root/macos/Scripts/upstream-footprint.sh"

git merge --no-edit upstream/main

echo "▸ Upstream changes since $before:"
git log --oneline "$before"..HEAD -- . ':!macos' | head -40

echo "▸ Upstream files the bridge depends on that changed:"
git diff --stat "$before"..HEAD -- src/backend.rs src/model.rs src/paths.rs src/util.rs Cargo.toml || true

"$root/macos/Scripts/sync-patches.sh" --lockfile
"$root/macos/Scripts/build-bridge.sh" debug

echo "✓ Upstream merged and the bridge builds. Run 'make test' and try the app."
