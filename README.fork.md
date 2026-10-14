<div align="center">

# Brisk

**A WhatsApp client that feels like a Mac app, because it is one.**

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)
![Apple silicon and Intel](https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Rust](https://img.shields.io/badge/Rust-engine-orange)
![Pre-release](https://img.shields.io/badge/status-pre--release-yellow)
![MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

Brisk links to your phone as a companion device, the same way WhatsApp Desktop does,
and shows your chats in a window built from SwiftUI and AppKit. There is no browser
engine, no Electron, no web view. The WhatsApp protocol and the encrypted message
archive come from the Rust engine of [ZapFast](https://github.com/crmne/zapfast), which
talks to WhatsApp through [whatsapp-rust](https://github.com/oxidezap/whatsapp-rust).

It started on 29 September 2026 as one commit, "Add a native macOS interface under
macos/", and grew into about 300 commits in two weeks: every message type, a media editor
and viewer, several accounts, locks, search, export, a performance rebuild of the
timeline and the window, and a full audit with fixes. This README is the long version of
what came out of that.

> [!NOTE]
> **Brisk is a working name.** The app, its bundle and its code are still called ZapFast
> inside, after the project it is built on. A final name will be chosen together with
> ZapFast's author; until then nothing here is endorsed by or affiliated with ZapFast.

> [!IMPORTANT]
> **Pre-release.** Build it from source for now. Signed, notarized downloads wait on one
> open license question (see [License](#license)) and on a release rehearsal. The
> [roadmap](ROADMAP.md) says what comes next.

> [!WARNING]
> **Unofficial.** Not affiliated with WhatsApp or Meta. Using an unofficial client may
> break WhatsApp's terms of service and could get an account suspended. Use it at your own
> risk.

## Contents

- [Why this exists](#why-this-exists)
- [Kept from WhatsApp, rebuilt for the Mac](#kept-from-whatsapp-rebuilt-for-the-mac)
- [Features](#features)
- [Performance](#performance)
- [The audit](#the-audit)
- [Calls: in development](#calls-in-development)
- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Your data and privacy](#your-data-and-privacy)
- [Built on ZapFast](#built-on-zapfast)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Why this exists

The official WhatsApp app for the Mac is heavy. Resizing the window stutters, long chats
get slower the further you scroll, and it does not behave like other Mac apps: its menus,
Settings, shortcuts and windows are its own. ZapFast fixed the weight with a Rust and egui
client that opens in under a second, but egui draws its own widgets, so on a Mac it still
does not feel like a Mac app.

This project takes ZapFast's engine and gives it the interface a Mac deserves:

- **Fast.** Chats open at once, long chats scroll smoothly however far you go, and the
  window resizes without lag. In the author's daily side-by-side use it is clearly faster
  than the official app, in scrolling as much as in resizing, and the whole app feels
  light in a way the official one does not. The [numbers](#performance) below are from
  the app's own benchmark; a controlled comparison with the official app is on the
  roadmap.
- **Native.** Real windows, a real toolbar and sidebar, the system's menus and Settings,
  keyboard shortcuts for everything, VoiceOver, Reduce Motion, light and dark, the accent
  colour from System Settings, and Liquid Glass on macOS 26.
- **Private.** No telemetry and no servers of its own. Messages live in a SQLCipher
  archive whose key is in your Keychain, one folder per account. Logs never hold message
  text, numbers or keys.
- **Open.** Every line is here to read, build and change.

## Kept from WhatsApp, rebuilt for the Mac

WhatsApp gets a lot right, and the parts people know by heart were copied carefully:
bubbles with tails at the end of a run, quotes that show what they answer, reactions on a
pill, the voice player with the sender's photo and a speed button, the media viewer with
the chat's media in a strip below, the unread divider, the media editor with crop, pen,
text and HD switch, the way a copied selection reads `[9:28, 30/09/2026] Ada: …`.

Everything around them was built again as a Mac app, not translated from the phone:

| Area | What is different |
|---|---|
| **Window** | An AppKit split view with a sidebar and a toolbar, the title bar a band the chat shows through. A narrow window shows one pane; the sidebar collapses to pictures. A chat can open in a window of its own. |
| **Chat list** | A source-list table with drawn rows. Filters for Unread, Direct, Favorites, Groups and Channels, plus your labels, Archived and Locked. Search finds chats, people you have no chat with yet, and messages. Pins slide, moves animate, the row under your pointer stays put. |
| **Search in a chat** | A bar over the chat, not a side panel: it counts matches, marks every word in every bubble, filters by sender, kind (photos, videos, files, links, voice, music) and day, and matches in any order, in Latin and Cyrillic, with every Uzbek apostrophe. |
| **Composer** | Laid out like Messages: a + panel of tiles, stickers in the field, Send replacing the microphone. Mentions with @, emoji with `:name`, paste a screenshot straight in, documents staged above the field with a caption. |
| **Settings** | A tab for each area, sized to its content like System Settings: General, Account, Chats, Notifications, Appearance, Privacy (Personal Info on the phone, This Mac locally) and Advanced. |
| **Menus and keys** | A real menu bar: File, Edit, View, Chat, Window, Help. ⌘1 to ⌘9 open the first nine chats, ⇧⌘] steps through them, ⌘F searches the chat, ⌥⌘F everything, ⌘I opens info, ⌃⌘L locks. ⌘/ lists them all. |
| **Look** | The Mac's own look by default (accent-colour bubbles on the window background), or WhatsApp's, or any of ZapFast's palettes, per chat if you like. Wallpapers: doodles, a colour, a gradient or your photo. |
| **System** | Notifications with Reply, a menu bar icon, a Share extension, Touch ID, a login item, Quick Look, drag and drop out of a bubble, Live Text in photos, Picture in Picture for video. |

## Features

**Messaging.** Text with WhatsApp's formatting, replies, edits (↑ in an empty composer
edits your last message), reactions with any emoji and the ones you use most first,
forwarding to several chats with a message after them, polls (create, vote, see who
voted), mentions, business messages (buttons, lists, carousels, copy-code), group invite
links that open in the app, Delete for Me that reaches the phone, Delete for Everyone
while it is allowed, Info with who read a message and when, multi-select with copy,
share, forward and delete, and disappearing-message timers marked on the chat's picture.

**Media.** Photos, videos (played in the bubble, one at a time, with the system's
controls), GIFs and animated stickers that play under the pointer, Lottie stickers, round
video messages, documents with the Finder's icon and the first page as a preview, voice
messages with the sender's waveform, link previews, shared contacts (Message, Add, Save
to Contacts), places on the sender's preview, and albums. Visible media downloads on its
own; what WhatsApp's servers no longer have is asked of the phone, and a file that does
not come says why.

**Media editor and viewer.** Photos and videos you send open in a dark editor laid over
the window: crop, straighten, flip, pen, marker, highlighter, a pixelate brush for faces
and numbers, text in three styles, emoji, trim and mute for video, undo and redo, a
caption per item, Standard or HD. Photos are re-encoded, so camera and location metadata
never leave the Mac. Clicking a photo in a chat opens the viewer: zoom like Preview, Live
Text, a strip of the chat's media, All Media by month, Share, Save, Forward, Reply, React.

**Voice messages.** Record in the message field's shape, with bars that follow your
voice; pause and listen back before sending; a refused send waits above the field. Voice
messages play in a row, one after the other.

**Stickers and GIFs.** A picker with favorites, recent, your packs and packs sent to you,
searchable by emoji or name. Make a sticker from a picture, create a pack, import a
signal.art pack or a `.wastickers` file, add a pack someone shared. GIFs come from GIPHY
with your own key.

**Chats and groups.** Archive, pin, mute (per chat, every channel at once, or group
messages quiet while mentions still sound), mark read or unread, labels, favorites synced
with the phone, chat info over the chat with members and a searchable member tab, rename a
group, change its photo, leave it, save a contact, start a chat with a contact, yourself
or a number.

**History.** Export a chat as a page to read in a browser, with its media in folders by
kind and a player for voice messages. Download from Phone fetches what the chat has on
the phone and this Mac does not, by kind, newest first, in the background. Older messages
come from the phone on request.

**Accounts.** Several WhatsApp accounts in one window, each with its own archive, cache
and key. Click your picture to switch; a dot shows unread chats elsewhere.

**Locks.** An app lock with a password or Touch ID that hides content from notifications
and the window; WhatsApp's chat lock, synced with the phone, opened here with a local code
or Touch ID.

**Mac.** Notifications with Reply that land on the message, a menu bar icon, open at
login, keep running when the window closes, a Share extension that puts files from
Finder, Photos or Safari above a chat's field, drag a downloaded file out of its bubble,
Quick Look for documents, a proxy for WhatsApp and media, a download folder of your
choosing.

**Languages.** English and Russian.

**Accessibility.** VoiceOver reaches what the pointer reaches, including Reply, React and
Select on a message and the steps of a voice waveform. Reduce Motion turns the slides and
pulses into fades and keeps stickers still.

## Performance

The chat list and the conversation are `NSTableView`s with cells drawn by Core Animation,
not SwiftUI rows. Text is laid out off the main thread, in parallel, before a row is
shown. Pictures are decoded into the display's pixel format on the decoder's thread. A
message that changes (a receipt, a download, a reaction) redraws its own row, not the
chat. The window and the chat pane are AppKit view controllers, so a resize never runs
SwiftUI's layout of the whole window; SwiftUI draws islands inside them (the composer, the
header, menus, sheets) that lay out only on their own changes.

The open chat keeps a bounded window of messages in memory (1,200 records per pane, with
pages of 60 read from the encrypted archive on demand), inactive chats are kept for at
most eight chats and 12,000 rows per account, and animated media, Lottie stickers and
thumbnails live under explicit size budgets. Nothing is lost: the archive has it all.

Every one of those decisions came from a measurement, and the measurements are kept in
[macos/PERFORMANCE.md](macos/PERFORMANCE.md) with the rules they led to. A few of them,
all on a MacBook Pro M3 Pro at 120 Hz, Release builds:

| What | Before | After |
|---|---|---|
| Resize step with a 121-row chat open, on the linked account | 215 to 490 ms (every row re-measured) | 16 to 30 ms |
| Open a 2,000-message chat | 940 ms | 150 to 185 ms |
| Scroll a fully loaded 2,000-message chat, hitch time | 55 to 106 ms/s | 1 to 4 ms/s |
| A message arriving in another chat, main-thread cost | 22 to 30 ms | 2 to 5 ms |
| Memory with a 2,000-message chat open | 240 MB | 115 to 135 MB |
| Peak memory with a 50,000-message chat open | 673 MiB | 216 MiB |
| Window shown after launch (Release, linked account) | | 0.27 s, chat list at 0.32 s |

In the audit's final synthetic run with 10,000 messages, frame work while scrolling the
whole chat was 2.74 ms at p95 and 3.58 ms at p99, against an 8.33 ms budget at 120 Hz,
with 39,707 rows checked and none blank or misplaced. The honest caveats: these are the
app's own synthetic benchmark (`--benchmark`, no account, media drawn into caches), the
50,000-message resize numbers still vary from run to run, and the official app was not
measured on the same workload yet. That comparison is the first item under
[performance on the roadmap](ROADMAP.md#4-performance-and-stability).

To run the benchmark yourself:

```sh
cd macos && make release
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_BENCHMARK_COUNT=10000 --args --benchmark
```

## The audit

Before publishing, the native interface went through a code, performance and release
audit (October 2026) with synthetic fixtures only, never the author's archive. It found 22
things. The five that blocked a release were fixed first, each with a regression test:

- a memory leak in the parallel text layout (initialized buffer elements were never
  released);
- location messages requested a map picture from Apple as soon as they scrolled into
  view, which sends a map area to a third party without being asked; previews are local
  now, and Apple Maps opens only on a click;
- the app lock did not cover a video call's picture or the camera;
- CI built and released upstream's egui app under the fork's name, not the native one;
- license notices were not bundled in the app.

The second round closed most of the rest: content-addressed thumbnail and Lottie caches
scoped by account, decode and extraction budgets, bounded loaded history, stale background
layouts no longer written to the cache, the new-message badge no longer counting older
history, call video backpressure, and one owner of the microphone and camera across
accounts. Still open, and listed on the roadmap: Keychain and database opening on the main
thread at launch, long audio held fully in memory, a few idle timers, and an unbounded
event queue between engine and interface.

The audit's own write-up, evidence and reproducers are kept out of the repository; the
findings and their state are summarised in the [roadmap](ROADMAP.md).

## Calls: in development

One-to-one voice and video calls and group voice calls are implemented and work in
development builds, but they have only been tested between the author's own devices. They
are **not part of public builds**: the bridge's `calls` Cargo feature is off by default,
public builds do not link the VoIP stack, and the app shows no call buttons, call rows or
call window. `make run CALLS=1` builds them for development. What works, what needs
testing and what comes later is under [Calls on the roadmap](ROADMAP.md#3-calls).

## Requirements

- macOS 15 or later. Liquid Glass and the newest controls need macOS 26.
- Apple silicon or Intel. Builds are universal; the Intel slice is built and validated by
  CI but has not been run on an Intel Mac yet. If you have one, a report is welcome.
- A phone with WhatsApp.

## Build and run

You need Xcode 26 or later, [rustup](https://rustup.rs) and
`brew install xcodegen cmake`.

```sh
git clone https://github.com/<owner>/<repo>.git
cd <repo>/macos
make run          # build and launch (Debug, Apple silicon)
```

```sh
make release      # optimised universal build (Apple silicon and Intel)
```

```sh
make ci           # every check CI runs: engine, bridge, Swift tests, warnings, inventory
```

On first launch, scan the QR code from WhatsApp on your phone (Settings › Linked
devices), or link with your phone number. Judge speed in a Release build: a Debug build
is not optimised and shows the window about five times later.

Developer notes, the keyboard table, the benchmark and the debug tools are in
[macos/README.md](macos/README.md); builds, CI and releases in
[macos/RELEASING.md](macos/RELEASING.md).

## Your data and privacy

- **No analytics, no telemetry, no servers of its own.** The app talks to WhatsApp, and
  to nothing else unless you ask: GIPHY for GIF search, Signal's servers for a signal.art
  sticker import, Apple Maps when you click a place.
- **The archive is encrypted** with SQLCipher. The key is a random one in your Keychain.
  Each account has its own folder under `~/Library/Application Support` and its own cache
  folder; removing an account removes both and its key.
- **Logs never contain message text, phone numbers or keys**, so they can go in a bug
  report.
- **Photos you send are re-encoded**, which leaves their location and camera details
  behind.
- **Locked means locked.** While the app lock is on, nothing is marked read, notifications
  say only "New message", and a call's picture is hidden.
- Help › Licenses and Notices opens the license, the asset notices and the full
  dependency inventory from inside the app.

More in [the privacy reference](docs/_reference/native-macos-privacy.md).

## Built on ZapFast

This app is built on [ZapFast](https://github.com/crmne/zapfast) by Carmine Paolino and
would not exist without it. ZapFast is a cross-platform WhatsApp client for Linux, macOS
and Windows written in Rust with egui; it is the inspiration here, not a competitor. If
you are on Linux or Windows, use ZapFast.

ZapFast's engine (the protocol through whatsapp-rust, the SQLCipher archive, settings,
palettes and media decoding) is linked without its egui interface, through a small Rust
bridge and UniFFI. Protocol, storage and sync behaviour are never reimplemented in Swift;
Swift talks to the engine only through its commands and events. Rules the engine exports
(how a chat is searched, how a phone number is told from a privacy id) are called, not
copied, so this app behaves exactly as ZapFast does.

Five changes were needed in the engine's own files, and they are offered back upstream:
document page previews, a hook that hands the WhatsApp client to an embedder, messages
that arrive inside a wrapper (albums, Lottie stickers, HD copies), the reason a file could
not be fetched, and addressing a direct chat to the phone by its privacy id (which is why
"older messages" requests get answered within seconds). Everything else lives under
`macos/`, and `make sync` merges upstream releases.

## Project layout

```
macos/
├── Bridge/            Rust crate zapfast-bridge: the engine behind UniFFI
├── Packages/ZapFastKit/
│   ├── ZapFastBridge/      generated Swift over the FFI
│   ├── ZapFastCore/        AppModel, stores, events, formatting (no views)
│   ├── ZapFastDesign/      tokens, colours, generic components
│   ├── ZapFastSharedUI/    components that need both the model and the kit
│   ├── FeatureOnboarding/  linking: QR, phone number, connection states
│   ├── FeatureChats/       the sidebar: search, chat table, filters
│   ├── FeatureConversation/ the open chat: timeline, drawn bubbles, composer, search
│   ├── FeatureSettings/    the Settings window
│   ├── FeatureLock/        the lock screen
│   ├── FeatureCalls/       the call panel (development builds)
│   └── ZapFastShell/       windows, toolbar, menus, app delegate
├── App/               the thin app target
├── ShareExtension/    the Share menu entry
└── Scripts/           bridge build, upstream sync, string catalog, license inventory
```

## Contributing

Issues and pull requests are welcome, and so are reports from an Intel Mac or from macOS
15. A few rules keep the fork healthy:

- Keep changes inside `macos/`. Anything the engine needs goes upstream first.
- Keep protocol, storage and sync logic in the engine; Swift shows, it does not decide.
- Never log message contents, phone numbers, keys or QR payloads, and never read a real
  archive while debugging. Tests use synthetic fixtures.
- New interface strings go through `Scripts/update-strings.py` and need a Russian
  translation, or CI fails.
- Run `make ci` before sending. One topic per commit, no merge commits.

The [roadmap](ROADMAP.md) lists what is planned, in priority order, if you are looking
for something to pick up.

## License

MIT, like ZapFast. Source and the app's own code can be used under it today.

One question stands between the source and a signed binary: `wacore-libsignal`, a
Signal-derived crate inside whatsapp-rust, declares MIT but carries Signal's AGPL-3.0
headers. The fork does not relicense it or describe the whole binary as MIT-only; the
release gate stays closed until upstream clarifies. The full dependency inventory is in
[macos/DEPENDENCY-LICENSES.md](macos/DEPENDENCY-LICENSES.md) and the review process in
[macos/RELEASING.md](macos/RELEASING.md).

## Credits

- [Carmine Paolino](https://github.com/crmne), for ZapFast, its engine and its palettes.
- The [whatsapp-rust](https://github.com/oxidezap/whatsapp-rust) contributors, for the
  protocol.
- [fastframe](https://github.com/crmne/fastframe), for the theme, logging and i18n
  crates the engine uses.
- Kamoliddin Fatkhullaev, for the macOS interface.
- Notification sounds from Pidgin (GPL-2.0), doodles drawn from Lucide icons (ISC),
  Lottie playback by [lottie-ios](https://github.com/airbnb/lottie-ios), phone numbers by
  [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit).

WhatsApp is a trademark of Meta Platforms, Inc. This project is not affiliated with or
endorsed by WhatsApp or Meta.
