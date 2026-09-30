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
- **On the linked account:** `open -n -a …/ZapFast.app --env ZAPFAST_STRESS=40`
  opens twelve chats that have nothing unread (so nothing is marked read),
  scrolls each, resizes the window, logs each round's cost (subsystem
  `ZapFast`, category `Stress`) and quits. Quit your own ZapFast first: only
  one copy runs. Category `Events` logs the backend events per kind and what
  applying them cost, every ten seconds.
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
| 09-30 | Benchmark with media (half of each chat), the pointer optional, rows checked every frame | with media: scroll hitches 55–85 ms/s, 200–350 with the pointer over the timeline; open 2,000 messages 940 ms (SwiftUI rows measured on the main thread); 240 MB |
| 09-30 | Rows, cells and hosting views back under Auto Layout (the overrides of `0dee224` removed) | rows found blank (a hosted row's view with no size): 2 of 5 runs → 0 of 5; scroll hitches with media unchanged within noise; text alone, frame work p50 2.3 → 2.9 ms |
| 09-30 | Photos, videos, GIFs and stickers drawn by Core Animation, measured off the main actor | open 2,000 messages 940 → 550 ms; open again 127 → 92 ms; jump p50 13 → 8 ms; scroll hitches unchanged within noise: the SwiftUI rows left (documents, voice, link previews) and the window's root are most of the scroll now |
| 10-01 | Documents, link previews and voice messages drawn too: no SwiftUI rows left in the benchmark | open 2,000 messages 550 → 160–185 ms; open again 92 → 58–72 ms; jump p50 8 → 3.5 ms; scroll hitches 60–100 → 38–62 ms/s, flicks 8–12; with the pointer over the timeline 200–350 → 44–66 ms/s; memory 240 → 120–134 MB |
| 10-01 | A message changed in place (a download, a receipt, a reaction) remakes its row only, not the chat's | scroll hitches 38–62 → 15–22 ms/s, flicks 4–6; with the pointer over the timeline 22–24 ms/s. The gaps between frames had been whole rebuilds of 2,000 rows as downloads finished |
| 10-01 | The chat's content in AppKit (`ConversationViewController`): the timeline a plain subview, the composer and what floats over it SwiftUI islands; the toolbar, sheets and search stay SwiftUI | scroll hitches 15–22 → 1–4 ms/s, flicks 0–3; open again 58 → 52 ms; resize step unchanged at 24 ms (the window's SwiftUI split view) |

### On the linked account

`ZAPFAST_STRESS=40` (see below) on the author's account: twelve chats read
already, 40 rounds. Main-thread time per step, median.

| Build | Open a chat | Scroll 2 s (chats of 100+ rows) | Resize | Longest frame gap |
|---|---|---|---|---|
| Branch as first delivered | 145 ms | 568 ms (960 ms) | 291 ms | 79 ms |
| Scroll kept out of Auto Layout and cursor passes, AppKit menu bar icon, caches across chats | 135 ms | 453 ms (858 ms) | 300 ms | 76 ms |

The account's chats hold documents, photos and voice messages, which are
still SwiftUI rows, so it gains less than the benchmark's text. Five
minutes of live traffic cost 1–3 ms of event handling and no idle CPU:
slowdowns come from what a person does, not from what arrives.

Paging frame work p50 went from 0.3 to 3–4.5 ms: the old timeline stopped
paging after two or three pages and then sat idle at the top, while the new
one keeps loading and drawing all sixteen. Its p99 is lower.

## Open

- **Launch waits about three seconds for the chat list on this account.**
  The Rust worker withholds chats and messages until it has confirmed which
  chats are locked on the phone. Here that recovery fails at every launch
  (`chat settings recovery failed (Snapshot): snapshot MAC mismatch` in
  `zapfast.log`), so the marker that would skip it is never saved and each
  launch waits for the attempt to fail. This is upstream and whatsapp-rust
  behaviour; a new link starts with an incremental sync instead.
- Resizing the window still lays out its SwiftUI root (the split view,
  toolbar and sidebar) on every step, about 24 ms. An AppKit window with
  an AppKit split view would take that away too.

- A message elsewhere still costs up to ~37 ms at the 99th percentile,
  the first time a chat moves to the top of the list.
- The source of the window's root `NSHostingView.layout()` while
  scrolling was the chat's own SwiftUI content around the timeline: every
  row the table added or moved invalidated it. It is AppKit now.
- Documents, voice messages, link previews, polls and cards are still
  SwiftUI rows, measured on the main thread once per bubble width. In a
  trace with media they were a quarter of the main thread while
  scrolling, most of it SwiftUI rendering their display lists again as
  they moved.

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
9. **Views that a table or a cell places by frame keep
   `translatesAutoresizingMaskIntoConstraints` as AppKit sets it.** Taking
   rows, cells and the cells' hosting views out of Auto Layout by answering
   no saved the window's SwiftUI layout while scrolling text, but left them
   without constraints: a layout pass now and then gave a hosted row's view
   no size, and the reader saw blank rows and flicker. The window's layout is
   kept out of scrolling by not being SwiftUI around the timeline, not by
   hiding views from Auto Layout.
10. **No per-cell tracking areas, cursor rects or tooltips.** The table
    tracks the pointer once and finds the row under it.
11. **No SwiftUI `MenuBarExtra`.** It is rebuilt with nearly every update in
    the app; an `NSStatusItem` changes only when its icon does.
12. **Anything a background queue runs is `nonisolated`,** and has a test
   that runs it on one. The package isolates to the main actor by default,
   and calling main-actor code from a `DispatchQueue` closure or an
   animation's completion handler is only a warning, which stops the app at
   run time. `make check` fails on any warning in ZapFastKit's sources.
13. **The timeline has no SwiftUI view above it that lays out on its
    changes.** Its pane is an AppKit view controller; the composer and what
    floats over the timeline are small SwiftUI islands beside it, not
    around it. Rows the table adds while scrolling invalidate layout up
    the view tree, and a SwiftUI ancestor answers by laying out and
    rendering all it holds again.
