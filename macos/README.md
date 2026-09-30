# ZapFast for macOS (native UI)

This repository is [crmne/zapfast](https://github.com/crmne/zapfast) with a
native macOS interface added under `macos/`. The WhatsApp side (whatsapp-rust,
the SQLCipher archive, media, keychain) is upstream's Rust backend, used
as-is. Only the interface is new: SwiftUI and AppKit, designed to Apple's HIG.

## Rules

1. **Never edit upstream files.** Everything outside `macos/` belongs to
   upstream. That keeps `git merge upstream/main` free of conflicts. When the
   bridge needs something upstream lacks, propose it upstream.
2. **The Rust side is the contract.** Swift talks to upstream only through
   `zapfast::backend::{Command, Event}`, via `macos/Bridge`. Protocol,
   storage and sync behaviour are never reimplemented in Swift.
3. **Pure upstream rules are exported, not copied.** Functions such as
   `search_key` and `phone_of` are exported from the bridge, so Swift behaves
   exactly like upstream.
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
│   ├── src/types/             FFI mirrors of upstream model types
│   └── uniffi-bindgen/        the binding generator binary
├── Packages/ZapFastKit/       Swift package, one module per layer
│   └── Sources/
│       ├── ZapFastBridge/     generated Swift over the FFI (+ conformances)
│       ├── ZapFastCore/       AppModel, stores, formatting (no views)
│       ├── ZapFastDesign/     tokens, asset colours, generic components
│       ├── ZapFastSharedUI/   components that need both the model and the kit
│       ├── FeatureOnboarding/ linking: QR, phone pairing, connection states
│       ├── FeatureChats/      the sidebar chat list
│       ├── FeatureConversation/ timeline (NSTableView), bubbles, composer (NSTextView)
│       ├── FeatureSettings/   the Settings window
│       ├── FeatureLock/       the app lock's lock screen
│       └── ZapFastShell/      scenes, split view, menus, app delegate
├── App/                       thin app target: @main, Info.plist, assets
├── Scripts/                   build-bridge, sync-patches, sync-upstream, print-link-libs
├── project.yml                XcodeGen spec (ZapFast.xcodeproj is generated)
└── Makefile
```

Dependencies point one way: `Shell → Feature* → SharedUI → Design + Core →
Bridge → FFI`. Features never import each other; the shell composes them.

### How events reach the interface

Upstream's worker calls `Waker::wake()` after each event. That waker wraps an
`egui::Context`; the bridge gives it a windowless context whose repaint
callback signals a pump thread. The pump drains `Backend::poll()`, converts
the events, and calls Swift's `EventListener`, which replays them on the
main queue in order. `Context::run_logic` re-arms the callback after each
drain, and a one-second timeout backs it up.

## Keyboard

| Keys | Does |
|---|---|
| ⌘N | New chat: a contact, yourself, or a phone number |
| ⌘F | Search the open chat (a panel beside it lists the matches) |
| ⌥⌘F | Search all chats: names in the sidebar, then matching messages |
| ⌘G / ⇧⌘G | Next / previous match in the open chat (older / newer) |
| ↑ ↓ Return | Walk the matches from the search field; Esc closes it |
| Return / ⇧Return | Send / new line in the composer |
| ↑ in an empty composer | Edit your newest message (up to 15 minutes old); Esc cancels |
| @ in a group's composer | Suggest members to mention; ↑ ↓ choose, Return or Tab picks, Esc closes |
| ⇧⌘R / ⇧⌘U | Mark the chat read / unread |
| ⌘I | Chat info: picture, number, members, mute / pin / archive |
| ⌃⌘L | Lock ZapFast (when an app lock password is set) |

Files picked with +, dropped on the chat, or pasted (⌘V, including a
copied picture or screenshot) wait above the field with a Quick Look
thumbnail; the text typed goes with them as the caption, and the reply
with the first. A send refused offline puts them back.

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
messages play in their circle. GIFs and animated stickers move while the
pointer is over them, as upstream's do.

Notifications sound as upstream's do: its receive sound for new
messages and its alert for a mention of you or a reply to you (Pidgin's
sounds, GPL-2.0 data files bundled from `assets/sounds`), the system's,
none, or a file of yours, chosen in Settings › Chats. Group messages can
stay quiet while mentions still sound, and a chat's menu gives it its
own sound.

A message of yours has Info in its menu: when it was delivered and read,
and in a group, by whom (from the receipts ZapFast recorded since the
message was sent). A chat's menu can clear its messages or delete it,
after asking, here and on the phone; both need a connection.

Settings › Privacy also shows who sees your last seen, online status,
profile photo and About, who can add you to groups, read receipts and
calls. The values live on the phone: they are read each time Settings
opens and changed one at a time.

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
pack. Besides that import, which downloads from Signal's servers, GIF
search is the only feature that talks to a third party: it asks
GIPHY, with your own key from Settings or one built in at compile time
through `ZAPFAST_GIPHY_KEY`, as upstream does. Emoji come from the
system's Character Viewer (⌃⌘Space).

Picking a match, or clicking the quote in a reply, scrolls to the message,
loading older history from the archive first when needed, and marks it for
a moment.

A chat opened with unread messages starts at "3 unread messages", above
the first of them, as upstream's does. While older messages are being
read, a button at the bottom returns to the newest one and counts the
messages that arrived below.

Pointing at a message brings React and Reply beside it, as upstream's
hover controls; React offers the quick reactions, and choosing yours
again takes it back. Everything else stays in the message's context menu.

## Build

Requirements: Xcode 26+, Rust via rustup (the toolchain comes from
`rust-toolchain.toml`), and `brew install xcodegen`.

```bash
cd macos
make          # Rust bridge → xcframework + Swift bindings, Xcode project, app build
make run      # build and open
make test     # ZapFastKit unit tests
```

Or `make bridge project` once, then work in `ZapFast.xcodeproj`. The scheme's
pre-action rebuilds the bridge before every build (log in
`Build/bridge-build.log`).

The app keeps its data in `~/Library/Application Support/<bundle id>` and
`~/Library/Caches/<bundle id>`, separate from upstream ZapFast.
Set `ZAPFAST_VERBOSE=1` for debug logging.

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
