# Native performance fixes: validation

Branch: `codex/native-audit-fixes`. Code candidate: `bd3b735`, compared with
the first-phase candidate `4b87256`. Only synthetic messages, media and
mock services were used. No real archive rows, contacts, session keys or
pre-existing user logs were read.

This is the `bd3b735` checkpoint. Later block snapshots, resize and call
recovery are validated in [the next checkpoint](LARGE-CHAT-CALL-VALIDATION.md).

## Checks

| Check | Result |
|---|---|
| Native Swift suite, committed dependency pins | PASS, 518 tests: 429 Core, 79 Conversation, 8 Chats, 2 Calls |
| Forced own-source warning gate | PASS, no ZapFastKit source warnings |
| Native arm64 Release app and Share extension | PASS, unsigned |
| Bundle architecture, native links and notice resources | PASS |
| Root fmt, default/all-feature clippy and tests, rustdoc with warnings denied | PASS |
| Root default/all-feature library tests | 1,137 passed and 8 ignored in each run, plus integration tests |
| Native dependency inventory consistency | PASS, 517 Rust packages and 2 Swift pins |
| Lock files and linear commit history | No lock changes or merge commits in this phase |

Machine-readable results: [performance-checks.json](evidence/performance-checks.json).
The engine-only 555 tests and Bridge 47 tests passed in the preceding phase;
they were not rerun here. Root source did not change in this performance phase.
Build logs remain ignored under `macos/Build/fix-performance-*.log` and
`macos/Build/performance-root-*.log`.

Regression coverage includes 150-frame decoded-byte budgets, rejected oversized
animations/archives, shared decoder concurrency, source deletion/replacement,
returning readers during cancellation, serial extraction cancellation, pinned
derived folders, obsolete layout completion, coalesced message revisions,
receipt/reaction/arrival updates preserving reading position and selection,
history badge counts, inactive retention and archive reload. The inactive
retention fixture loads 50 chats with 3,000 rows each and preserves an open
15,000-row chat. It validates model row retention, not a hard process RSS cap.

## CPU profile and focused correction

Time Profiler attached only to a process launched with `--benchmark`, using
50,000 synthetic messages. The full-history phase contains fifteen `Here`
signposts. In the `c1e360b` profile, the main thread had 575 ms of sampled CPU
in these intervals. `TimelineController.refresh(rows:)` appeared in 359 ms;
`initializeWithCopy for TimelineController.Item` appeared in 185 ms.
These inclusive samples overlap and must not be added together.

The implementation kept `var updated = items` before replacing one row,
forcing the entire item array to copy on mutation. `bd3b735` updates the
main-actor-owned item array directly. The existing reaction/receipt/append
tests and a new coalesced journal test verify row changes, reading anchor,
selection and arrival count. The store's ID index is a reference owned by
the store, so passing it into merge does not share its dictionary storage.

Only aggregated symbols and sampled weights are saved in
[reference-profile-summary.json](evidence/reference-profile-summary.json).
Raw traces and exports were removed because profiler metadata can include
the target process environment. Profiling overhead means these sampled
numbers are not substitutes for the unprofiled A/B runs.

The `bd3b735` follow-up profile, again fifteen full-history `Here` intervals,
had 226 ms sampled main-thread CPU. `refresh(rows:)` appeared in 8 ms and
no `initializeWithCopy for TimelineController.Item` samples were observed.
Store update/merge still appeared in 48 ms and array allocation/copy frames
remain. This supports removal of the identified item-copy path, while
leaving other model and UI costs visible. Samples from two runs are not a
controlled speed ratio. See
[reference-profile-after-summary.json](evidence/reference-profile-after-summary.json).

## Release A/B method

The same Mac15,7 (M3 Pro, 18 GiB), macOS 27.0.1 build 26A434, Xcode 27 beta /
Swift 6.4 and Rust 1.98 were used. Both binaries are unsigned arm64 Release
builds with the same dependency pins. The window is 1100 by 740 points,
the timeline approximately 794 points, and the display 120 Hz.

Each executable runs its own `--benchmark` with `ZAPFAST_BENCHMARK_COUNT`
set to 10,000 or 50,000, then quits. The fake backend uses a separate
benchmark preference suite and cache. Pointer hover is disabled. The driver
runs one app at a time. Own builds, tests and profilers are stopped during
timing. The 10k sequence is AB, BA, AB to vary run order; 50k is one AB pair.
Binary SHA-256 values and run metadata are recorded in
[reference-performance-comparison.json](evidence/reference-performance-comparison.json).
Text outputs replace local home/workspace paths and strip trailing whitespace;
metric values are preserved in the JSON reports.

`messageHereMs` is main-thread CPU over an 80 ms settling interval minus
median idle CPU, not end-to-end delivery latency. Scroll frame work and
resize step measurements are wall time. Footprint is physical footprint
at one sampling point, divided by 1024 squared, hence MiB despite the
JSON field's `MB` name. A median of per-run p95 values is not a pooled p95.

This was not an isolated idle host. The pre-run snapshot reports load
averages around 12 and approximately 5.97 GiB swap used. Those observations
limit causal and absolute-speed claims; they do not prove the cause of any
regression. See [host pressure](evidence/reference-performance-host-pressure.json).

### Current candidate results

10k entries below are medians of three per-run values. The range is shown
for event CPU p95. 50k entries are one run per binary.

| Metric | 10k baseline A | 10k candidate B | 50k baseline A | 50k candidate B |
|---|---:|---:|---:|---:|
| Current-chat event CPU p95, ms | 18.29 (17.54 to 20.42) | 12.45 (6.47 to 12.66) | 60.21 | 17.86 |
| Full-scroll frame work p95, ms | 3.79 | 3.90 | 5.89 | 5.00 |
| Resize step p95, ms | 17.85 | 20.01 | 13.03 | 18.84 |
| Sampled physical footprint, MiB | 106.66 | 107.11 | 239.92 | 193.53 |

All three 10k pairs have lower current-chat event CPU p95 for the candidate.
The 50k pair also improves that metric. Scroll improvement is not established
by the 10k results; resize medians are higher for the candidate. The candidate
event CPU median still exceeds 8.33 ms at both sizes, so F11 remains partially
open. Footprint is sampled after switching to a small chat and scrolling the
sidebar, not while the full large chat remains active. It is not peak memory.

The eight current runs checked 307,915 rendered rows in 46,654 checks, with
zero missing or misplaced rows. All 24 runs across the three candidate series
checked 916,634 rows, also with zero missing or misplaced rows. This integrity
result covers the exercised synthetic scrolling scenarios, not every UI state.
Individual reports retain p50/p95/p99, hitches, frame counts and phase timings.
Aggregates and ranges: [performance-summary.json](evidence/performance-summary.json).

## Earlier candidates

Earlier A/B evidence is retained, including regressions. The `performance-*`
series measured `e7ad4a0`; the `final-performance-*` series measured
`595adb4`. The word `final` in those filenames does not identify the current
candidate. Their metadata records the actual commit and binary hash.

The earlier series varied widely. In the `595adb4` 50k pair, current-chat
event CPU p95 was 64.52 ms for baseline and 101.99 ms for candidate; resize
p95 was 13.42 ms and 72.91 ms. That result was not accepted as a completed
performance fix and led to the targeted CPU profile and array-copy correction.

## Remaining limits

F09 now has explicit native decode/extraction/cache budgets, but ImageIO,
Core Animation and Lottie internal peak heap usage was not measured.
Parsed-model cost is estimated; active disk leases can temporarily exceed
the pruning budget. Long recording/audio and call video backpressure are
separate open audit items.

F10's inactive model retention is bounded. An active chat's loaded history
and timeline still grow with its row count. A hard active-history budget
requires paging in both directions while preserving position.

F11's full scans and item-copy paths were reduced. Message-array copy,
other lookups, full rebuilds and resize scaling remain. An 8.33 ms frame
budget is not guaranteed. No official WhatsApp speed ratio or linked-account
idle CPU/energy result follows from these synthetic tests.

Execution on macOS 15/26, Intel, live WhatsApp calls, real microphone/camera,
hosted CI, signing, notarization and a second-Mac Gatekeeper install remain
untested here. F05's upstream license clarification and distribution review
remain open; the release gate still refuses a pending review. No push,
release, notarization submission or external message was performed.
