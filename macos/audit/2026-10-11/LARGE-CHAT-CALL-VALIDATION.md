# Large chats, resize and call recovery

Branch: `codex/native-audit-fixes`. Final code: `92203dc`. This follows the
`bd3b735` performance checkpoint. The measured candidate is `97c99c9`; later
call wiring/permission fixes, resize tests and benchmark preference isolation
do not change the measured timeline paths.
Final test harness: `6c5e3fd`. Validation completed on October 12 in
Asia/Tashkent; the evidence remains with the audit begun on October 11.
Only synthetic messages and mock call/capture services were used. No personal
archive rows, contacts, keys or pre-existing user logs were read.

## Changes

`a517010` replaces message-array snapshots with a value-semantic
`MessageHistory` collection of 256-record blocks. Updating a receipt or adding
a message copies the affected block and the outer block references, rather
than all 50,000 records retained by a timeline snapshot. Prepend, deletion,
sorting and full layout still rebuild data when necessary. This is not a cap
on active history or an O(1) guarantee for every mutation.

`2f28f80` resolves reading anchors, unread placement and jumps through the
timeline's row-ID index. `ed1da73` stops forcing nested layout/anchor restoration
inside width-only parent placement. A change to the bubble width still
reflows messages and restores the reading anchor after the result installs.
Height/inset changes continue to maintain the reader's position or bottom
following. Regression cases exercise both 40 and 50,000 messages, a width
change under the same bubble cap, narrow reflow, and height/bottom-inset changes.

`476d8aa` moves blocking call-history FFI reads to one serial queue per account.
The view gets an empty call list immediately, then an observable update.
Concurrent requests coalesce, newer live reports override a disk snapshot,
and cancellation/account reset prevents stale installation. This changes
first-load timing: messages can appear briefly before their call rows.

`8195c62` bounds the native video inbox to eight pending access units and
4 MiB, rejects a unit above 1 MiB, and schedules one drain. Stream reset drops
queued data immediately. Overflow, malformed format and renderer readiness
failure discard the dependent chain and wait for a keyframe, with requests
limited to one per second per stream. One additional unit can be in processing;
AVFoundation surfaces and Rust queues are outside this bound.

`97c99c9` adds process-wide call media ownership, including pending place/answer
reservations. Another account gets a busy notice while its incoming call
continues ringing. Switching accounts keeps the existing call running.
Removal, unlink and shutdown retire pending/current calls, release media,
cancel history reads and disconnect the listener/renderer retention cycle.
Permission and capture callbacks are bound to the originating call lifecycle.

Final review also reproduced a pending microphone permission blocking a new
call after account reset. Reset now releases the intent gate immediately;
completion of the old task cannot clear a newer intent's gate. The regression
fails on the preceding source and passes after the correction, without
opening a microphone. Its result is included in the check evidence.

Camera startup reports actual capture success. Failure/interruption turns the
camera off with a notice while voice continues. Retry is explicit. Stopped
microphone/encoder callbacks cannot feed a later call; a failed audio-device
restart reports an error and ends the affected call. Locking stops remote
decoding and local camera capture; unlocking resumes remote video only.
See [call behavior and bounds](../../../docs/_reference/native-macos-call-recovery.md).

## Validation

The final checks and source commit are recorded in
[large-chat-call-checks.json](evidence/large-chat-call-checks.json).

| Check | Result |
|---|---|
| Native Swift tests, committed pins | PASS, 539: 449 Core, 80 Conversation, 8 Chats, 2 Calls |
| Forced own-source warning gate | PASS, no ZapFastKit source warnings; final fixture guard also compiled without warnings |
| Native arm64 Release app and Share extension | PASS, unsigned, final production source `92203dc` |
| Bundle architecture, native links and bundled notices | PASS |
| Root fmt, default/all-feature clippy and tests, warning-denied rustdoc | PASS, six checks |
| Root library tests | 1,137 passed, 8 ignored in each configuration, plus integrations |
| Native license inventory | PASS, dependency pins unchanged |

The Bridge's 47 tests and engine-only 555 tests passed in the first phase;
they were not rerun in this phase. Rust/Bridge source did not change. Own build
logs are ignored under `macos/Build/large-call-*` and `call-fixes-tests.log`.
The 50,000-row resize stress test shares the process layout scheduler with
other AppKit tests, so serial execution is used for the final suite.
An earlier parallel attempt exhausted a small fixture's wait deadline and
failed; that attempt is not counted as passing validation. Its test-process
trap was in `SweepTests.middle`, indexing an unprepared fixture after its
five-second wait. The fixture now requires loaded rows before indexing them,
so a future timeout becomes a test failure instead of a process trap. Only
selected frames from this session's synthetic test crash are retained in
the check evidence; no pre-existing application crash/log was read.

Coverage includes retained 50k snapshots, receipt/append/delete/order behavior,
nonzero-index slices, reading anchors after reflow, off-main call reads,
read/report races, reset cancellation, a 10,000-unit video burst, stream reset,
request throttling, capture failure, late output, lock/unlock, pending call
retirement, multi-account ownership and failed audio restart. Capture tests
use mock configuration and do not open a real camera or microphone.

## Release timing evidence

Same Mac15,7, M3 Pro/18 GiB, macOS 27.0.1, Xcode 27 beta/Swift 6.4, arm64
unsigned Release and committed dependency pins. Each synthetic benchmark
uses a 1100 by 740 point window, a 794.5 point timeline and no pointer hover.
Own builds, tests and profilers were stopped during timing. The host was not
isolated, so variation from unrelated activity limits causal speed claims.
The benchmark now skips window-frame autosave to avoid changing normal app
preferences. Its previous runs already set the measured frame explicitly.

[large-final-comparison.json](evidence/large-final-comparison.json) records
binary SHA-256 values and the order: 10k AB, BA, AB; 50k AB, BA. A is `bd3b735`,
B is `97c99c9`. The following values are medians of each run's p95, not pooled
percentiles. Ranges retain all runs, including regressions.

| Metric, ms | 10k A | 10k B | 50k A | 50k B |
|---|---:|---:|---:|---:|
| Current-chat event CPU p95 | 6.62 (6.00 to 12.33) | 11.18 (5.40 to 12.27) | 19.24 (17.62 to 20.86) | 13.66 (11.07 to 16.26) |
| Full-scroll frame work p95 | 3.85 | 4.37 | 4.02 | 5.00 |
| Resize step wall p95 | 14.31 (13.07 to 20.64) | 22.82 (14.10 to 24.51) | 18.74 (12.08 to 25.39) | 26.13 (18.62 to 33.64) |

Both 50k pairs reduce current-chat event CPU p95. The 10k pairs are mixed and
the aggregate is worse. Scroll and total resize improvement are not established;
their aggregate values are higher. The two 50k resize pairs move in opposite
directions. These results do not establish a general performance win or a
120 Hz frame-budget guarantee. The fixes remove identified copying/layout
paths and preserve position; overall resize performance remains open.

Event cost is main-thread CPU over an 80 ms settle period, minus median idle
CPU. It is not delivery latency. Scroll/resize work is wall time including
layout, drawing and Core Animation commits. Resize takes ten 8-point steps;
the narrow reflow regression is a separate test, not a timed full-window
drag through every width. Footprint is sampled after opening a small chat,
not while the large chat is active. Its wide variation is not evidence of
bounded active memory, peak usage or leak absence.

The ten current A/B runs performed 58,642 checks of 381,286 rendered rows,
with zero missing or misplaced rows. The six earlier `2f28f80` runs are also
retained. Across all sixteen runs in this phase, 93,780 checks of 611,294 rows
found zero missing or misplaced rows. See
[aggregates and all ranges](evidence/large-chat-call-summary.json),
[earlier metadata](evidence/large-chat-comparison.json) and the individual
JSON/text reports in `evidence/`. This covers the exercised synthetic states.

## Sampled CPU profile

Time Profiler attached only to the synthetic benchmark PID with 50k messages.
Fifteen full-history `Here` intervals and ten `ResizeStep` intervals are
aggregated in [the final profile](evidence/large-final-profile-summary.json).
Only symbols/weights are retained; raw traces and process metadata were
removed. The target inherited a whitelist of ordinary launch variables,
without credential-bearing variables.

The final `Here` phase has 81 ms sampled main-thread CPU. Store update appears
in 1 ms; timeline append/update in 26 ms; array-buffer allocation/copy in
10 ms. Remaining timeline allocations are visible. Resize has 126 ms sampled
main-thread CPU: `place` appears in 2 ms and no `restore` samples were observed.
The parent NSWindow layout appears in 99 ms, SwiftUI render in 40 ms,
NSHostingView layout in 27 ms and toolbar layout in 25 ms. Inclusive frames
overlap and must not be added together. A missing sampled frame does not prove
zero cost.

The earlier `2f28f80` profile is
[retained](evidence/large-chat-profile-summary.json): 60 ms for `Here`, 95 ms
for resize, `place` in 10 ms and `restore` in 7 ms. These separate sampled runs
support examining the removed nested path, not a controlled overall speed ratio.
Neither profile includes linked-account call/media stress.

## Still open

- F10: active history/timeline remain proportional to loaded rows. A hard
  active budget needs bidirectional paging with position preservation.
- F11: full rebuild/reflow, remaining timeline allocations and parent
  AppKit/SwiftUI/toolbar layout. Total resize speed has not been proved better.
- F14: startup Keychain/SQLite open and backend/pump shutdown waits remain.
- Calls: real Android/iPhone inbound/outbound, Bluetooth/route changes,
  camera unplug, sleep/wake, packet loss, slow decoder and simultaneous
  accounts need live testing. Keep calls experimental; group video,
  screen sharing and call-link/join UI remain incomplete.
- Runtime coverage: macOS 15/26 and Intel were not executed here. Minimum
  macOS 15 is a compilation target, not runtime validation. Hosted CI,
  signing, notarization and second-Mac installation were not performed.
- F05: license clarification/distribution review is still pending. The
  release gate remains closed. No push, release or external message occurred.

No official WhatsApp performance ratio or idle CPU/energy claim follows
from these synthetic runs.
