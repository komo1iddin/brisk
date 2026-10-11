# Native audit fixes: validation

Branch: `codex/native-audit-fixes`. Synthetic fixtures only; no user archive,
messages, contacts, session keys or pre-existing user logs were inspected.

| Check | Result |
|---|---|
| Root fmt | PASS |
| Root engine-only clippy / unit tests | PASS, 555 tests, 8 ignored |
| Root default/all-feature clippy | PASS |
| Root default/all-feature tests | PASS, 1,137 library tests in each run plus integration checks |
| Root all-feature rustdoc with warnings denied | PASS |
| Bridge fmt, all-target clippy, unit tests | PASS, 47 tests |
| Native full Swift suite with committed pins | PASS, 489 tests |
| Forced own-source native warning gate | PASS |
| Release artifact / license guard fixtures | PASS, 5 tests |
| GitHub Actions actionlint / shellcheck | PASS |
| Native dependency inventory consistency | PASS, 517 Rust packages and 2 Swift pins |
| Full local native CI rehearsal | PASS |
| Native Release, arm64 app and Share extension | PASS, unsigned |
| Real bundle identifiers, native framework links and 3 notice resources | PASS |
| Pending license review blocks distribution | PASS, expected refusal |

The changed thumbnail test uses distinct raw RGBA PNGs and asserts their
bytes differ. Restoring the old cache identity caused its two cache assertions
to fail; the content-aware implementation passed. The initial audit probe's
color fixture was unreliable on this beta toolchain and has been corrected.

F01's lifetime tests cover 0, 1, 32, 33, 64, 65 and 129 rows and twenty
parallel batches. F03 uses mocked permission/camera services, including
permission races and late camera state updates. F07 covers matching filenames
in different accounts, replacement bytes and removed source files. F08 covers
first rotations 0/1/3 in consecutive calls and pre-reset queued callbacks.

## Updated synthetic timeline run

Release executable, 10,000 messages, the same Mac15,7 / macOS 27.0.1,
1100x740 window, 794 pt timeline and 120 Hz display as the baseline audit.
This run used the direct executable and ran after build jobs finished.

| Metric | Post-fix run |
|---|---:|
| Full-scroll frame work p50 / p95 / p99 | 0.58 / 2.74 / 3.58 ms |
| Full-scroll hitches over 8 seconds | 4 |
| Current-chat message event p50 / p95 | 11.20 / 12.22 ms |
| Resize p95 | 11.37 ms |
| Physical footprint at benchmark sampling point | 108.08 MiB |
| Integrity rows checked | 39,707 |
| Missing / misplaced rows | 0 / 0 |

Raw [text](evidence/fixes-timeline-10000.txt) and
[JSON](evidence/fixes-timeline-10000.json) are saved. The benchmark labels
footprint as MB but divides by 1024 squared. The lifetime regressions establish
F01's ownership fix; this single benchmark run is not a repeated performance
A/B experiment. The remaining large-history event/resize work still exceeds
an 8.33 ms frame budget, so the later performance backlog remains relevant.

## Coverage limits and outstanding release work

Executed on this Apple Silicon Mac with Xcode 27 beta / Swift 6.4 and Rust
1.98. The app targets macOS 15; macOS 15/26 execution and Intel were not tested.
The GitHub-hosted workflow, Developer ID certificate import/signing, Apple
notarization and a second-Mac Gatekeeper install were not executed. Their
configuration is ready for a credentialed rehearsal after license review.
No live WhatsApp call, microphone/camera capture or network interoperability
claim follows from the mock tests. No official WhatsApp A/B, linked-account
idle CPU or energy measurement was performed.

F05 remains open: upstream Signal-derived license declarations conflict and
some published package sources lack full license texts. The inventory and
bundled notices are implemented, with a pending review gate and an unsent
upstream question. No push, release, notarization submission or upstream
message was performed.

Build logs remain under `macos/Build/fix-*.log` and are ignored by Git.
