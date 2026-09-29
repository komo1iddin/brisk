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
| ⌘F | Search the open chat (a panel beside it lists the matches) |
| ⌥⌘F | Search all chats: names in the sidebar, then matching messages |
| ⌘G / ⇧⌘G | Next / previous match in the open chat (older / newer) |
| ↑ ↓ Return | Walk the matches from the search field; Esc closes it |
| Return / ⇧Return | Send / new line in the composer |
| ⇧⌘R / ⇧⌘U | Mark the chat read / unread |

Picking a match scrolls to it, loading older history from the archive
first when needed, and marks it for a moment.

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
