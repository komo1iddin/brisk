#!/usr/bin/env bash
# What this fork has done to upstream's tree, and so where the next merge
# can hurt.
#
# A merge conflicts per file. A file upstream does not have cannot conflict,
# whatever directory it sits in; only a file that exists on both sides can.
# So this prints the two lists separately: what is ours alone, and what we
# have edited of upstream's, which is the whole of the risk.
#
#   macos/Scripts/upstream-footprint.sh [base-commit]
#
# The base is the merge point with upstream/main, or whatever commit is
# given. Run it before `make sync`.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

base="${1:-}"
if [[ -z "$base" ]]; then
  base="$(git merge-base HEAD upstream/main 2>/dev/null || true)"
fi
if [[ -z "$base" ]]; then
  echo "No base commit. Pass one, or 'git fetch upstream' first." >&2
  exit 1
fi
echo "Against upstream at $(git rev-parse --short "$base") ($(git log -1 --format=%s "$base"))"
echo

ours="$(mktemp)"; theirs="$(mktemp)"
trap 'rm -f "$ours" "$theirs"' EXIT
git ls-tree -r --name-only HEAD -- src/ | sort > "$ours"
git ls-tree -r --name-only "$base" -- src/ | sort > "$theirs"

echo "Ours alone, which upstream can never conflict with:"
only=0
total=0
while read -r f; do
  [[ -f "$f" ]] || continue
  n="$(wc -l < "$f" | tr -d ' ')"
  printf '  %-44s %6s\n' "$f" "$n"
  only=$((only + 1)); total=$((total + n))
done < <(comm -13 "$theirs" "$ours")
echo "  $only files, $total lines"
echo

echo "Upstream's, edited here: every one of these can conflict."
echo "The bigger the change, the worse the next merge."
risk=0
git diff --numstat "$base" HEAD -- src/ \
  | while read -r add del f; do
      grep -qxF "$f" "$theirs" || continue
      printf '%6s %s\n' "$((add + del))" "$f"
    done \
  | sort -rn \
  | while read -r churn f; do
      printf '  %-44s %6s changed\n' "$f" "$churn"
    done
risk="$(git diff --numstat "$base" HEAD -- src/ \
  | while read -r a d f; do grep -qxF "$f" "$theirs" && echo "$f"; done | wc -l | tr -d ' ')"
echo "  $risk files"
echo
echo "A deletion counts as much as an insertion: moving upstream's code out"
echo "of one of its files is as much of a conflict as adding to it."
