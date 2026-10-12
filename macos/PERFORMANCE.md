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

- **Verify activity and visibility.** Launch through LaunchServices (`open`),
  or activate an isolated synthetic child before measurement. Every recorded
  `windowActivity` check must be active and visible, with nominal thermal
  state. Exclude the whole run if those conditions fail. Profiling and
  floating-window diagnostics are separate from unprofiled A/B timings.
- **Use enough resize samples.** `ZAPFAST_BENCHMARK_RESIZE_ROUNDS=4`
  repeats the same ten 8 pt steps, restoring the width between rounds.
  The default remains one round. With only ten samples the current p95 is
  the maximum. `resizeSamples` records wall, main-thread and process CPU
  for each step; batch CPU includes run-loop pauses and width restoration.
  Scroll CPU fields cover the display-link run, before its final settling
  pause, and include work outside the timed frame callback.
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
  one copy runs. `ZAPFAST_STRESS_HOLD=8` then keeps each chat at its top
  for eight seconds, so the phone is asked for older messages and answers
  while the chat is open; `ZAPFAST_STRESS_CHATS=<n>` takes more chats.
  Category `Events` logs the backend events per kind and what applying them
  cost, every ten seconds, and category `Hangs` every time the main thread
  did not answer for 250 ms or more, in every build and run.
- **Launch time:** the app logs `Launch: <step> after N ms` from the
  moment the process started (Console.app, subsystem `ZapFast`, category
  `Launch`, or the Xcode console). A slow start under Xcode that is fast
  from the Finder is the debugger, not the app.
- **Judge speed in Release.** A Debug build (`make run`) is not optimised:
  on the linked account it showed the window 1.36 s after the process
  started, a Release build 0.27 s, with the chat list at 0.32 s. Every
  number here is Release.
- **A hang names its place:** category `Hangs` logs up to four stacks of
  the main thread while it was stuck, as `image+offset` (`atos -o <image>
  -l 0 <offset>` reads one back).

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
| 10-01 | The main window in AppKit (`MainWindowController`: split view, toolbar, sidebar and chat controllers; SwiftUI only in islands) | on the linked account, a chat of 121 rows, 40 resize steps of 12 pt each with 8 ms of run loop: step median 20–30 → 16 ms, first step 370 → 9–10 ms, worst 33 ms |
| 10-01 | The sidebar's rows drawn (`ChatCell`), each following its own chat; the chat's header and menu given the chat without its latest activity; the menu bar given the Go to Chat names; the sidebar's toolbar items set only on change; the islands over the timeline and the composer read the pane's state; arriving messages added to the rows in place | four alternating runs against `a6f0535`: a message elsewhere p50 8–12 → 1.8–3.2 ms with 2,000 rows, 9–14 → 3.4–4.2 with a page; a message in the open chat 24–31 → 9–12 ms with 2,000 rows, 19–23 → 8–9 with a page; chat list scroll hitches 4–19 → 0 ms/s in three runs of four; the rest unchanged within noise |

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

On 10-01 the freeze the author reported ("after the history spinner, the
app cannot be used") was measured in their own window: one chat, its
history loaded to 121 rows, the window narrowed and widened by 240 pt in 80
steps from inside the app (lldb, `setFrame` then 8 ms of run loop per
step), Debug builds.

| Build | Typical step | Steps over 100 ms | 80 steps |
|---|---|---|---|
| `main` (`92981d3`) | 215–490 ms | 80 | 27.4 s |
| This branch (`81dd178`) | 20–30 ms | 1 (the first, 370 ms in both builds) | 2.4 s |

On `main` each step asked every row's height again (`TimelineController.resized`
→ `noteHeightOfRows`), and each SwiftUI row was measured on the main thread
(`RowMeasurer`), 6.7 s of 8.9 s sampled: the more history loaded, the longer
each step. With 400 pt of narrowing, where bubbles change width, this branch
takes 17–76 ms a step. The same twelve-chat stress with eight seconds at the
top of each chat logged ten hangs of 0.3–1.3 s on `main` and none on this
branch after launch.

## Open

- **Connecting takes about three and a half seconds on this account.** On
  10-01 a Release launch showed the chat list from the archive 0.32 s after
  the process started and was connected at 3.6 s. Earlier the chat list
  itself waited about three seconds: the Rust worker withholds chats until
  it has confirmed which are locked on the phone, and here that recovery
  failed at every launch (`chat settings recovery failed (Snapshot):
  snapshot MAC mismatch` in `zapfast.log`). That is upstream and
  whatsapp-rust behaviour.
- A message elsewhere still costs ~20 ms at the 95th percentile with a
  page open, the first time the other chat moves to the top of the list
  (the same before and after the drawn rows).
- Polls, places, contacts, business cards and sticker packs are still
  SwiftUI rows in the timeline, measured on the main thread once per bubble
  width; they are rare.

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
13. **No SwiftUI view holds the timeline or the window's content.** The
    windows, the split view, the sidebar and the chat are AppKit view
    controllers; the composer, the header, the rows and what floats over
    the timeline are small SwiftUI islands beside them, not around them.
    Rows the table adds while scrolling invalidate layout up the view
    tree, and a window resize lays out everything in it: a SwiftUI
    ancestor answers either by laying out and rendering all it holds.
14. **What changes with every message reaches SwiftUI as a value that
    changes only when what the view shows does.** The chat's menu read the
    whole chat and SwiftUI rebuilt it for every message (a fifth of what a
    message cost); the header, the composer's place and the islands over the
    timeline were evaluated again each time, and the menu bar's Go to Chat
    read the whole sidebar order. An AppKit controller that reads the
    stores anyway (it costs microseconds there) hands views
    `ChatSummary.withoutActivity`, names, or flags, set only when they
    change; toolbar items are set only when they change, since any change
    lays the toolbar out again.
15. **In a sidebar, draw as SwiftUI does there.** The sidebar's appearance
    is vibrant: AppKit's system colours take other values there than
    SwiftUI's (use `NSColor(Color.red)` and the like), and SwiftUI draws
    secondary and tertiary styles vibrant, so drawn rows put those in a
    view that allows vibrancy. Compare in the sidebar gallery, captured as
    the window server composites it; `cacheDisplay` gets layer colours
    wrong.
