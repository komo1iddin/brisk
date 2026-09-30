#!/bin/zsh
# Fails when ZapFastKit's own sources build with warnings.
#
# Some Swift 6 concurrency errors are downgraded to warnings (calling main-actor
# code from a DispatchQueue closure, for one) and crash at run time; warning
# control can't promote them to errors. The generated bridge is left out.
#
#   Scripts/check-warnings.sh    (from macos/, after `make bridge`)
set -euo pipefail
cd "${0:a:h}/../Packages/ZapFastKit"
# Recompile everything of ours: a cached build prints no warnings.
find Sources Tests -name '*.swift' -not -path '*/Generated/*' -exec touch {} +
output=$(swift build --build-tests 2>&1 | sed -E $'s/\x1b\\[[0-9;]*m//g')
if print -r -- "$output" | grep -q 'error: Build failed\|: error:'; then
  print -r -- "$output" | grep -E ': error:' | sort -u
  exit 1
fi
warnings=$(print -r -- "$output" | grep -E '/Packages/ZapFastKit/(Sources|Tests)/.*: warning:' | grep -v '/Generated/' | sort -u || true)
if [[ -n "$warnings" ]]; then
  print -r -- "$warnings"
  exit 1
fi
print "No warnings in ZapFastKit sources."
