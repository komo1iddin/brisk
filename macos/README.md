# ZapFast for macOS (native UI)

This repository is [crmne/zapfast](https://github.com/crmne/zapfast) with a
native macOS interface added under `macos/`. The WhatsApp side (whatsapp-rust,
the SQLCipher archive, media, keychain) is upstream's Rust backend, used
as-is. Only the interface is new: SwiftUI and AppKit, designed to Apple's HIG.

## Rules

1. **Never edit upstream files.** Everything outside `macos/` belongs to
   upstream. That keeps `git merge upstream/main` free of conflicts. When the
   bridge needs something upstream lacks, propose it upstream. The two
   exceptions so far are listed under [Following upstream](#following-upstream).
2. **The Rust side is the contract.** Swift talks to upstream only through
   `zapfast::backend::{Command, Event}`, via `macos/Bridge`. Protocol,
   storage and sync behaviour are never reimplemented in Swift.
3. **Pure upstream rules are exported, not copied.** Functions such as
   `search_key` and `phone_of` are exported from the bridge, so Swift behaves
   exactly like upstream. Numbers are written with PhoneNumberKit
   (libphonenumber's formats, as WhatsApp writes them) once `phone_of` says
   an id is a phone number.
4. **Privacy as upstream:** never log message contents, phone numbers, keys
   or QR payloads, and never read `archive.db` contents while debugging.

## Layout

```
macos/
├── Bridge/                    Rust crate `zapfast-bridge` (UniFFI → Swift)
│   ├── src/client.rs          BridgeClient: start / send / shutdown
│   ├── src/pump.rs            wakes Swift when the backend has events
│   ├── src/commands.rs        BridgeCommand → upstream Command
│   ├── src/events.rs          upstream Event → BridgeEvent (exhaustive match)
│   ├── src/helpers.rs         exported pure upstream helpers
│   ├── src/calls/             voice calls on the worker's WhatsApp client
│   ├── src/types/             FFI mirrors of upstream model types
│   └── uniffi-bindgen/        the binding generator binary
├── Packages/ZapFastKit/       Swift package, one module per layer
│   └── Sources/
│       ├── ZapFastBridge/     generated Swift over the FFI (+ conformances)
│       ├── ZapFastCore/       AppModel, stores, formatting (no views)
│       ├── ZapFastDesign/     tokens, asset colours, generic components
│       ├── ZapFastSharedUI/   components that need both the model and the kit
│       ├── FeatureOnboarding/ linking: QR, phone pairing, connection states
│       ├── FeatureChats/      the sidebar (AppKit): search, chat table, filter
│       ├── FeatureConversation/ the open chat (AppKit): pane, timeline (NSTableView, drawn cells), composer
│       ├── FeatureSettings/   the Settings window
│       ├── FeatureLock/       the app lock's lock screen
│       ├── FeatureCalls/      the call panel
│       └── ZapFastShell/      AppKit windows (split view, toolbar), Settings scene, menus, app delegate
├── App/                       thin app target: @main, Info.plist, assets
├── Scripts/                   build-bridge, sync-patches, sync-upstream, print-link-libs
├── project.yml                XcodeGen spec (ZapFast.xcodeproj is generated)
└── Makefile
```

Dependencies point one way: `Shell → Feature* → SharedUI → Design + Core →
Bridge → FFI`. Features never import each other; the shell composes them.

### The windows

The main window and a chat's own window are AppKit: `MainWindowController`
holds an `NSSplitViewController` (the sidebar, `SidebarViewController`; the
chat, `ChatDetailViewController`; the chat's search as the inspector) and
one `NSToolbar` whose items those controllers make. The lock screen and
linking take the split view's place. SwiftUI draws islands inside them that
lay out only on their own changes (rows, the header, the composer, menus,
notices) and presents the sheets from small presenter islands; Settings and
the menu bar's commands stay SwiftUI scenes. Resizing the window never runs
SwiftUI's layout of the whole window.

### How events reach the interface

Upstream's worker calls `Waker::wake()` after each event. That waker wraps an
`egui::Context`; the bridge gives it a windowless context whose repaint
callback signals a pump thread. The pump drains `Backend::poll()`, converts
the events, and calls Swift's `EventListener`, which replays them on the
main queue in order. `Context::run_logic` re-arms the callback after each
drain, and a one-second timeout backs it up.

With Reduce Motion on, stickers and GIFs stay still under the pointer
and ZapFast's slides, pulses and growth turn into fades or nothing. On
macOS 26 the floating controls are Liquid Glass drawn in groups (the
composer, a message's Reply and React), and a chat you cannot write to
shows why in the same glass. VoiceOver reaches what the pointer does: a
message's actions include Reply, React and Select, the voice waveform
steps by tenths, and suggestions and notices are announced.

Settings has a tab for each area, as the Mac's own apps do: General
(login, menu bar, running in the background, downloads), Account, Chats
(text size, Return, voice message photos, contacts), Notifications,
Appearance, Privacy and Advanced (proxy, GIPHY key, log). Each keeps a
set height and scrolls, so the window fits the screen.

## Keyboard

| Keys | Does |
|---|---|
| ⌘N | New chat: a contact, yourself, or a phone number |
| ⇧⌘] / ⇧⌘[ | Next / previous chat in the sidebar, wrapping around |
| ⌘1 … ⌘9 | The first nine chats in the sidebar (Chat › Go to Chat; names hidden while locked) |
| ⌘L | Put the cursor in the composer |
| ⌥⌘↓ | Scroll to the newest message |
| Page Up / Page Down | Scroll the messages, also from the composer |
| Home / End in an empty composer | Oldest loaded / newest message |
| ⌘/ | Keyboard shortcuts (Help › Keyboard Shortcuts) |
| ⌘+ / ⌘− / ⌘0 | Bigger / smaller / actual size message text (View menu, or Settings › Chats) |
| ⌘F | Search the open chat (a panel beside it lists the matches) |
| ⌥⌘F | Search all chats: names in the sidebar, then matching messages |
| ⌘G / ⇧⌘G | Next / previous match in the open chat (older / newer) |
| ↑ ↓ Return | Walk the matches from the search field; Esc closes it |
| Return / ⇧Return / ⌘Return | Send / new line / send in the composer (with Return sends off in Settings › Chats: new line / new line / send) |
| ↑ in an empty composer | Edit your newest message (up to 15 minutes old); Esc cancels |
| @ in a group's composer | Suggest members to mention; ↑ ↓ choose, Return or Tab picks, Esc closes |
| ⇧⌘R / ⇧⌘U | Mark the chat read / unread |
| ⌘I | Chat info over the chat, as a click on its header: picture, number, members, search / mute / pin / archive, leave / clear / delete |
| ⌃⌘L | Lock ZapFast (when an app lock password is set) |

The composer is laid out as in Messages, with system buttons (Liquid
Glass on macOS 26): + opens a panel of tiles for a file,
photos and videos, a poll or a new sticker; the stickers button sits in the field; Send
replaces the microphone once there is something to send.

Documents picked with +, dropped on the chat, or pasted wait above the
field with a Quick Look thumbnail; the text typed goes with them as the
caption, and the reply with the first. A send refused offline puts them back.

Photos and videos (picked, dropped, or pasted with ⌘V, including a copied
picture or screenshot) open the media editor, as on the phone: a dark window
laid over the whole ZapFast window, sidebar and toolbar included, that
follows it as it moves and resizes. Its title bar drags and zooms the
window, and its red traffic light or ⌘W closes it.
Each gets its own caption, and the strip at the bottom switches between them
(← →) or adds more. Photos can be cropped (free or to an aspect ratio),
straightened with the dial, turned and flipped; drawn on with a pen, marker,
highlighter, or a pixelate brush that hides faces and numbers; and given
text (three styles, any colour) or emoji, which move with a drag and size and
turn with a pinch and twist on the trackpad or the corner knob. Videos can be
trimmed and sent without sound, and take text, emoji and drawings too. ⌘Z and
⇧⌘Z undo and redo, Delete removes the picked text or emoji, Escape leaves a
tool and then closes (asking first when there are edits); the caption goes
back to the field. The HD button chooses the quality, kept for next time:
Standard sends photos at most 1600 pixels on the longer side and videos at
960 × 540, HD at 4096 pixels and 1920 × 1080 (an untouched HD video goes as
it is). Photos are always redrawn as JPEG, which leaves their location and
camera details behind. Prepared files wait in the caches folder's
`Outgoing` until upstream has read them and are cleared after a day.

While a voice message records, pause stops it and lets go of the
microphone (the system's indicator goes out); paused, the play button
plays back what is recorded so far and the microphone goes on recording.
The bars glide in from the right and follow the voice's loudness, scaled
to the loudest it has lately been, with silence as a dotted line; the
recording field has the message field's shape, so the two swap in place.
Return sends; Escape or the bin discards, asking first once the take is
ten seconds or longer.

A voice message refused offline waits above the field ("Voice message
(0:07) not sent") until Send tries it again or the cross discards it.

A photo, video or GIF clicked in a chat opens the media viewer, as in
WhatsApp: a window laid over ZapFast's, in the Mac's light or dark look,
with who sent it and when, and Share, More (Show in Chat, Copy Image, Open
With Default App, Show in Finder, Info), Delete, Edit and Send (into the media
editor), Forward and Save. Below are the chat's media in a strip, All Media
(a grid by month), React, Reply and Done; what is not downloaded yet
downloads as it opens, and reaching the oldest asks for more. Photos zoom as
in Preview (pinch, double-click, ⌘+ ⌘− ⌘0) and carry Live Text, so their text
can be selected and copied; videos have the Mac's floating controls with
speed and Picture in Picture. ← → or a two-finger swipe step through, ⌘C
copies the photo, ⌘S saves, Escape zooms out and then closes. Round video
messages still play in their bubble, and stickers open in Quick Look.

A WhatsApp group invite link (chat.whatsapp.com/…) clicked in a message
opens here: the group's name, members and description, then Join, or
Request to Join where admins approve. File › Join Group with Link… takes
a pasted link.

Business messages show their card: picture, text and buttons, or a
strip of carousel cards. Quick replies and list choices answer the
message (only visible indices leave the interface; the worker resolves
them from the archived message), links open, and copy-code buttons
copy. Calls, forms and payments point to the phone, as upstream's do.

Chats look like the Mac's own apps by default: bubbles in the accent
colour chosen in System Settings on the window's background, as in
Messages. Settings › Appearance, laid out like System Settings, picks
another theme (bubble colour and wallpaper together, WhatsApp's look
among them), a bubble colour (the system accent, a preset, or any from
the colour panel), and a wallpaper: none, the doodles or a plain colour
(WhatsApp's colours for light and dark), a soft gradient, or a photo of
yours, dimmed in dark appearance. A chat's menu gives it its own theme
(Chat Theme…), and Use Default Theme returns it to the default. Themes
stay on this Mac. The doodles are upstream's `assets/wallpaper.svg`,
drawn from Lucide icons (ISC).

Videos play inside their message, one at a time, with the system's
controls (full screen and Picture in Picture included); round video
messages play in their circle. A video played before it is here starts
once its download lands, if its chat is still open. GIFs and animated stickers move while the
pointer is over them, as upstream's do.

Notifications sound as upstream's do: its receive sound for new
messages and its alert for a mention of you or a reply to you (Pidgin's
sounds, GPL-2.0 data files bundled from `assets/sounds`), the system's,
none, or a file of yours, chosen in Settings › Notifications. Group messages can
stay quiet while mentions still sound, and a chat's menu gives it its
own sound.

A message of yours has Info in its menu: when it was delivered and read,
and in a group, by whom (from the receipts ZapFast recorded since the
message was sent). A chat's menu can clear its messages or delete it,
after asking, here and on the phone; both need a connection.

Settings › Privacy also shows who sees your last seen, online status,
profile photo and About, who can add you to groups, read receipts and
calls. The values live on the phone: they are read each time Settings
opens and changed one at a time. Read receipts and typing for this Mac sit there too.

Settings › Privacy sets an app lock, as upstream's: a password asked at
start and after 1 minute, 15 minutes or an hour without use, or at once
with ⌃⌘L. Touch ID can open it instead. Only a salted PBKDF2 verifier
is kept; while locked nothing is marked read and notifications say only
"New message". It encrypts nothing more, and a forgotten password means
unlinking.

A chat's menu can lock it with WhatsApp's chat lock, which syncs with
the phone. Locked chats leave the list, search, badges and
notifications, and open under Locked Chats with a local code (set the
first time, changed in Settings › Privacy) or Touch ID. Going back or
closing the window locks them again; they are read-only here, as
upstream's are.

The smiley button in the composer opens stickers (favorites, recent,
packs, and ones sent to you, searchable by emoji or its name) and GIFs.
A sticker pack someone shares opens with View: its stickers can be sent
from there, and Add to My Stickers keeps it among the picker's packs;
a pack's menu in the picker sends it to the open chat, or deletes it.
The picker's + makes a sticker from a picture (a square dragged into
place and sized; sent, or kept in Favorites), creates a pack of your
own to file stickers into from their menu, or imports a signal.art
pack or a `.wastickers` file (the archive WhatsApp's sticker apps share,
chosen in the open panel upstream shows for it). Besides that import, which downloads from Signal's servers, and
the maps of shared places (below), GIF search is the only feature that
talks to a third party: it asks GIPHY, with your own key from Settings or
one built in at compile time through `ZAPFAST_GIPHY_KEY`, as upstream does. Emoji come from the
system's Character Viewer (⌃⌘Space).

Typing `:` and part of a name (`:grin`) offers matching emoji above the
field, ranked as upstream ranks them (its `emojis` data, exact shortcodes
first); ↑ ↓ choose, Return or Tab picks, Escape closes. A bare `:`
offers the ones picked most recently.

The calendar beside the in-chat search field keeps the search to one
day; a day with nothing typed lists that day's messages, as upstream's
does.

Picking a match, clicking the quote in a reply, or clicking a
notification scrolls to the message,
loading older history from the archive first when needed, and marks it for
a moment.

A chat opened with unread messages starts at "3 unread messages", above
the first of them, as upstream's does. While older messages are being
read, a button at the bottom returns to the newest one and counts the
messages that arrived below.

Settings › General › Files sends new downloads to a folder of your
choosing (upstream's `download_folder`) instead of ZapFast's cache;
files already downloaded stay where they are. Settings › Advanced takes
a proxy for WhatsApp, media and GIF search (`http://`, `socks5://` or
`socks5h://`, checked as upstream checks it), used from the first
connection and reconnecting when changed; empty follows `ALL_PROXY` or
`HTTPS_PROXY`.

Settings › General opens ZapFast at login (a login item, the
system's own record, as upstream keeps none of its own), shows its icon
in the menu bar with upstream's tray menu (open, lock, quit; never a
chat's name), and keeps it linked in the background when the window
closes, or quits instead.

The chat open when ZapFast quits opens again at the next start, as
upstream's `last_chat` does; one removed or locked since is forgotten.

A chat opened from the Unread list stays listed there once read, so its
row does not leave from under the pointer, until the filter changes, as
upstream's does. With channels followed, the filter menu mutes or
unmutes them all.

The Share menu of other apps (Finder, Photos, Safari and the rest) lists
ZapFast: the extension, in its own sandbox, only notes what was shared
and opens ZapFast, which asks which chat it goes to (Send to…) and puts
the files above that chat's field and any text in it, so a caption can
be added and nothing is sent until Send. System Settings › General ›
Login Items & Extensions › Sharing turns the entry on or off.

A chat's menu opens it in a window of its own (Open in New Window),
with its composer, search and info; a chat there is read and kept quiet
in notifications as the main window's is. The window shows nothing while
the app lock is closed.

A shared contact shows the person and their number, read from the card
by upstream's rules (the `waid` WhatsApp adds, else an international
number): Message opens their chat, Add saves them when they are not a
contact yet, and the message's menu has Save to Contacts… (the card goes
to the Contacts app, which asks first) and Copy Number. A place shows
an Apple Maps picture of the streets around it with a pin, as WhatsApp
does, then its name and address; a live location says when it last
moved, how fast and how precisely. Unlike upstream, which shows only the
sender's small preview, this sends Apple the place's coordinates when the
bubble first appears (MapKit draws the map); the pictures are kept in
memory only, and the sender's preview shows until the map is drawn or
when it cannot be. A click opens Apple Maps (upstream opens
OpenStreetMap); Copy Coordinates is in the menu.

Select in a message's menu, or ⌘-click, starts selecting messages: a
click adds or removes one, ⇧-click a run of them, and the bar in place of
the composer copies, shares, forwards them (oldest first) or deletes them
from ZapFast on this Mac after asking; Esc stops. Copy takes one message's
text as it is, and several as the phone does, a line each with the time,
date and who wrote it (`[9:28, 30/09/2026] Ada: …`), with markers such as
`[photo]` for what is not text. Share hands on the downloaded files and
the other messages as that text. Deleted, phone-only and unsupported
messages cannot be selected, as upstream's.

Forward opens "Send to", as on the phone: your own chat first, then the
chats that can receive, newest first, each with its members or number
under the name. Click chats to tick as many as you like (Return in the
search field ticks the first match), optionally add a message, and
Forward; a double-click forwards at once. The added message waits until
the forwarded ones have left for each chat, so it arrives after them; if
they never do, it goes back to that chat's composer instead of out alone.

Pointing at a message brings Reply and React beside it, as discs clear
of the bubble, as upstream's hover controls. React (or More Reactions…
in the message's menu) offers six quick reactions, the ones you use most
first, and + opens every emoji by category with a search field;
choosing yours again takes it back. Everything else stays in the
message's context menu.

A downloaded photo, video or document drags out of its bubble to the
Finder or another app, under the name it was sent with (a copy, so
ZapFast's own file stays).

A document shows a badge for its kind, as WhatsApp's do (a red PDF, a
blue W), and, above it, the top of its first page: a PDF's drawn by Quick
Look once the file is here, else the page preview WhatsApp keeps on its
media servers, fetched once when the document first shows, else the
sender's small inline preview.

In a group, someone not in your contacts has their number beside their
name, over their messages and in quotes of them; Settings › Chats turns
the numbers off. Names take WhatsApp's colours, one of their own for each
member of the group while there are enough.

Voice messages show the photo of whoever recorded them at the end of the
player, with a microphone that turns blue once yours was played; while
one plays, the speed control takes the photo's place. Settings › Chats
turns the photos off.

### Voice calls

A person's chat has a phone button and a video button in the toolbar. An incoming call rings
in a small panel at the top right of the screen, over other windows and
Spaces, and bounces the Dock; Return answers, Esc declines. While the app
lock is closed the panel says only "WhatsApp Call". During a call the
panel shows the time and has Mute and End; the ringback plays while the
other side's phone rings. A second call during one rings as a banner over
the panel with two beeps: Decline, or End & Accept (WhatsApp has no hold).

Calls are whatsapp-rust's: the bridge turns its `voip` features on (MLOW,
libopus for peers outside the MLOW rollout, the UDP relay) and receives
the worker's client through `zapfast::backend::set_client_hook`, since
upstream's interface has no calls. Audio crosses the bridge as 16 kHz mono
frames of 60 ms; Swift captures and plays them through one `AVAudioEngine`
with the system's voice processing, which cancels the speaker's echo.

A chat shows its calls among its messages, as centred rows ("Missed voice
call · 14:05", "Voice call · 2 min · 14:05"): the calls the phone syncs
through app state (`call_log`), and those rung or placed here, the phone's
record winning. Upstream's archive has no place for them, so the bridge
keeps `State/calls.db`, encrypted as the archive is (SQLCipher, its own
random key in the keychain). The phone sends its whole call history only
when the device links; a device linked before this version shows the calls
from now on.

Video calls: a video offer can be answered with voice or video, the camera
button turns ours on or off at any time (on a voice call it asks the other
side to switch, and their request shows as Not Now / Switch), and the panel
then shows them full size with ourselves in a corner. The library carries
H.264 only: Swift captures with `AVCaptureSession`, encodes with
VideoToolbox (Constrained Baseline, 720p at 20 fps, 1.5 Mbit/s, the
parameter sets before each keyframe and a keyframe when the other side
asks) and shows theirs through `AVSampleBufferDisplayLayer`, asking for a
keyframe after a loss.

Group calls are voice only for now. A group chat has the phone button
(not the video one) and rings everyone in the group; an incoming group call
names the group and who is calling. The panel lists who has joined (or who
is still being rung), the library mixes their voices into one stream, and
one member leaving or declining ends the call for nobody else. A video
group call can be joined with voice.

Not yet: video in group calls, and a third call at once (that offer keeps
ringing on the phone).

## Build

Requirements: Xcode 26+, Rust via rustup (the toolchain comes from
`rust-toolchain.toml`), and `brew install xcodegen`.

```bash
cd macos
make          # Rust bridge → xcframework + Swift bindings, Xcode project, app build
make run      # build and open
make test     # ZapFastKit unit tests
```

Before merging, `make check` recompiles ZapFastKit, fails on any warning
in its sources (some Swift 6 isolation errors are only warnings, and crash
at run time), and runs the tests.

Or `make bridge project` once, then work in `ZapFast.xcodeproj`. The scheme's
pre-action rebuilds the bridge before every build (log in
`Build/bridge-build.log`).

The app keeps its data in `~/Library/Application Support/<bundle id>` and
`~/Library/Caches/<bundle id>`, separate from upstream ZapFast.
Set `ZAPFAST_VERBOSE=1` for debug logging. Each launch logs how long its
steps took (`Launch: … after N ms`, subsystem `ZapFast`, category `Launch`),
and a main thread that stops answering for 250 ms or more logs how long
(`Hang: …`, category `Hangs`) and where it was (`Hang stack …`: code
addresses as `image+offset` with the nearest exported symbol, no data), so a
freeze can be found afterwards. An offset in the app's own image reads back
with `atos -o <image> -l 0 <offset>`.

Judge speed in a Release build (`make run CONFIG=Release`): a Debug build is
not optimised, and on the author's Mac it showed the window after 1.4 s where
Release did after 0.27 s.

## Timeline benchmark

`--benchmark` opens the real window on made-up group chats instead of the
linked account (no backend, no archive, own preferences), measures the
message timeline, prints a report and quits. It times opening a chat,
scrolling up at 5,000 pt/s while older pages of 60 arrive, scrolling a fully
loaded chat, quick flicks up and back down, jumps, resizing, scrolling the
chat list, and what a message or presence change in another chat, and a
message in the open one, cost the main thread. The
phrases and speed match Telefast's benchmark, so the numbers compare.

About half of each chat is what real chats hold besides text: photos,
documents, voice messages, videos, stickers and link previews, drawn into
the benchmark's caches once, with downloads that finish a moment after the
timeline asks. Every frame it also checks that each visible row, its cell
and the cell's parts are where the table put them; the report's
`Integrity` line counts rows that were not (a blank or flickering
timeline), and any at all is a bug.

```bash
cd macos
make release
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_BENCHMARK_COUNT=10000 --args --benchmark
```

Launched through `open`, the app is active as a person uses it; run old and
new builds alternately to compare them. [PERFORMANCE.md](PERFORMANCE.md)
keeps the results, how they were taken, and the rules that came out of
them.

`ZAPFAST_BENCHMARK_COUNT` sets the fully loaded chat's size (default 2,000).
`ZAPFAST_BENCHMARK_MEDIA=0` makes the chats text alone, as the first runs
were. The window ignores the pointer unless `ZAPFAST_BENCHMARK_POINTER=1`;
`=over` places it so the resting pointer is over the timeline, as when
scrolling with a trackpad. `ZAPFAST_BENCHMARK_DELAY=<seconds>` waits before
starting, to attach Instruments; each scroll step is a `Frame` interval in
Points of Interest.
Each event is an interval too (`Presence`, `Elsewhere`, `Here`).
`ZAPFAST_SWIFTUI_ROWS=1` shows every message as the earlier SwiftUI row
instead of the drawn bubble, and every chat in the sidebar as the earlier
SwiftUI `ChatRow`, to compare them, in the app or the benchmark. In a Debug
build, `ZAPFAST_SNAPSHOT_TIMELINE=/path/to.png` draws a gallery of messages
through the real timeline twice, drawn bubbles on the left and SwiftUI rows
on the right, in light and dark, and quits; `ZAPFAST_SNAPSHOT_SIDEBAR=/path/to.png`
does the same for made-up chats in every state a sidebar row shows, with a
chat selected, captured as the window server composites them (which is
where vibrancy and colours can be compared).
Each run's JSON lands in `~/Library/Caches/<bundle id>/benchmarks/`.
A Debug build also takes commands from a shell
(`DistributedNotificationCenter`, name `com.komoliddin.ZapFastMac.debug`,
the command as the object): `tree` writes the main window's views and
safe areas, `resize:<steps>:<points>` times each step of a resize,
`select:<n>` opens a chat, `top:<n>` loads older pages, `open:search` and
the like open parts of the window, `shot` captures the window as shown,
and `action:<selector>` sends an action (`action:terminate:` quits). Answers go to
`~/Library/Caches/<bundle id>/debug/` and name views and numbers only.

## Following upstream

```bash
cd macos && make sync
```

This merges `upstream/main`, copies upstream's `[patch.crates-io]` and
lockfile into the bridge (Cargo honours patches only at the workspace root),
and builds the bridge. A compile error then says exactly what changed:

- a new `Event` variant fails `events.rs`: map it, or list it under "not bridged yet";
- a new or renamed field fails the matching `From` in `types/`;
- a changed `Command` fails `commands.rs`.

If the app stops linking after a bump, run `Scripts/print-link-libs.sh` and
update the `ZapFastBridge` linker settings in `Package.swift`.

Two changes live in upstream's files in this fork, to be offered upstream:

- fetching a document's page preview (`Command::FetchPreview`,
  `src/backend/worker/document_preview.rs`, `Archive::set_thumbnail`);
- handing the worker's WhatsApp client to an embedder for calls
  (`src/backend/client_hook.rs`, one line in `start_bot`).

A merge may conflict there; keep upstream's side and re-apply that commit.
The bridge names upstream's whatsapp-rust revision to add the VoIP
features; `Scripts/sync-patches.sh` keeps the two revisions equal.
