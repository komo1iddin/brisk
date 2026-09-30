# Performance

What was measured in the macOS interface, what changed because of it, and
the rules that came out of it. Many of the rules were first measured in
Telefast, a sibling native client built the same way (AppKit timeline,
SwiftUI around it), and then applied and measured here.

## Measuring

```bash
cd macos
make release
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_BENCHMARK_COUNT=2000 --args --benchmark
```

The report lands in `~/Library/Caches/<bundle id>/benchmarks/`. Things
that decide whether two numbers can be compared:

- **Launch through LaunchServices** (`open`), as above: the app is then
  active and focused, as a person uses it. Launching the binary directly
  gives other numbers.
- **Compare A/B, alternating.** Results depend a lot on what else the Mac
  is doing. Build the old commit in a worktree, copy both `.app`s aside,
  and run old, new, old, new, at least three times each. The first run
  after a build is cold; do not compare it with a warm one.
- **Keep the pointer off the window** while it runs: rows under a resting
  pointer make their hover views.
- **Trace a slow moment** with Time Profiler attached to that run:
  `xcrun xctrace record --template 'Time Profiler' --time-limit 60s --attach <pid>`.
  `xctrace --launch` starts the app inactive and hides hitches.
- **Launch time:** the app logs `Launch: <step> after N ms` from the
  moment the process started (Console.app, subsystem `ZapFast`, category
  `Launch`, or the Xcode console). A slow start under Xcode that is fast
  from the Finder is the debugger, not the app.

## History

MacBook Pro M3 Pro, 120 Hz. Benchmark with 2,000 messages in the full
chat, 200 chats, three alternating runs of each build.

| Date | Change | Result (before → after) |
|---|---|---|
| 09-30 | Views read one chat, one download at a time; sidebar list apart from its toolbar | message elsewhere p99 36–41 → 23–31 ms; full-chat scroll hitches 188–284 → 97–98 ms/s |
| 09-30 | Text messages drawn by Core Animation, measured off the main actor | resize step 2.1–3.4 s → 24 ms; jump p95 105–140 → 6–11 ms; reopen a chat 232–340 → 65–73 ms; full-chat scroll hitches 100–176 → 1.6–5 ms/s; paging no longer stalls (3 → 15 pages); memory 153–185 → 97–121 MB |
| 09-30 | Unread and channel counts kept beside the chats; menu bar icon its own view; sidebar sorted by position | message elsewhere p50 18–21 → 4–5 ms |
| 09-30 | All of the above against `main` | resize 2.3–2.7 s → 23–25 ms; jump p95 98–126 → 5–10 ms; reopen 290–446 → 59–87 ms; message elsewhere p50 22–30 → 4–7 ms; memory 132–184 → 98–102 MB |

Paging frame work p50 went from 0.3 to 3–4.5 ms: the old timeline stopped
paging after two or three pages and then sat idle at the top, while the new
one keeps loading and drawing all sixteen. Its p99 is lower.

## Open

- A message elsewhere still costs up to ~37 ms at the 99th percentile,
  the first time a chat moves to the top of the list.
- While scrolling, the window's root `NSHostingView.layout()` and tracking
  area updates still show in traces; their source is not found yet.
- Photos, voice, polls and cards are still SwiftUI rows, measured on the
  main thread once per bubble width.

## Rules

Each of these came from a trace or a benchmark.

1. **Nothing observable is read that a view does not show.** A view that
   shows one chat reads that chat's slot (`chat(_:)`, `conversation(_:)`,
   `download(_:)`, `typing(in:)`, `presence(of:)`, `draft(for:)`), never a
   whole dictionary. Counts that menus, badges and icons show are stored and
   set only when they change (`pinnedCount`, `unreadChatCount`,
   `channelCount`).
2. **Scenes' bodies read nothing that changes often.** A value read there
   rebuilds every window, menu and command, and the menu bar icon.
3. **Scrolled cells set frames directly.** No `needsLayout`, no Auto Layout
   constraints, no `NSTextField`: they send the window's layout pass
   through its SwiftUI root on every reuse. Hosting views in cells are sized
   by autoresizing masks.
4. **Custom drawing goes into layers with `contentsFormat = .RGBA8Uint`.**
   AppKit picks 16-bit buffers on XDR displays, which doubled the cost of
   every frame. Shapes (bubbles, chips) are layer backgrounds with corner
   radii, drawn by the GPU; shadows get a `shadowPath`.
5. **Layout that can run off the main actor does,** in parallel for many
   rows, and a table asks for heights it already has.
6. **Decoded pictures are converted for the display on the decoder's
   thread** (`DisplayImage.prepare`). Otherwise Core Animation converts them
   while committing, on the main thread.
7. **Hover work waits until the pointer rests** (150 ms): text views for
   selection and the Reply and React controls are made then, not for every
   row the pointer crosses while scrolling.
8. **Lists change by their own operations,** not by reloading: moves slide,
   rows arriving from far away fade in, and when the reader has scrolled
   away the first row on screen keeps its place.
9. **Anything a background queue runs is `nonisolated`,** and has a test
   that runs it on one. The package isolates to the main actor by default,
   and calling main-actor code from a `DispatchQueue` closure or an
   animation's completion handler is only a warning, which stops the app at
   run time. `make check` fails on any warning in ZapFastKit's sources.
