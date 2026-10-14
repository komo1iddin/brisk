# Roadmap

This is the plan for Brisk (a working name; see the README) after its first public
source release. It is ordered by priority, not by date. Items move when they are done,
verified, and documented.

**Legend:** ✅ done · 🔨 in progress · 📋 planned · 🔭 exploring · ⛔ blocked on an
external dependency

**Guiding rules.** Speed and privacy come first. The Mac interface talks to the engine only
through commands and events. Changes outside `macos/` go upstream first. A feature is
announced only after it works against a real account, not when a protocol field for it
exists.

---

## Contents

1. [Now: first public source release](#1-now-first-public-source-release)
2. [Next: first signed release](#2-next-first-signed-release)
3. [Calls](#3-calls)
4. [Performance and stability](#4-performance-and-stability)
5. [Features](#5-features)
6. [Localization and accessibility](#6-localization-and-accessibility)
7. [Upstream and library work](#7-upstream-and-library-work)
8. [Not planned](#8-not-planned)
9. [Done](#9-done)

---

## 1. Now: first public source release

Goal: a clean, buildable, honest public repository.

| Status | Item |
|---|---|
| ✅ | **Calls separated from the main app.** The bridge's `calls` Cargo feature is off by default: public builds do not link the VoIP stack and show no call buttons, call rows or call window. `make run CALLS=1` builds them for development. |
| ✅ | **Universal build.** `make release` builds for Apple silicon and Intel. |
| ✅ | **Russian interface,** from a string catalog kept in step with the code by `Scripts/update-strings.py`. |
| ✅ | Public README and roadmap. |
| 📋 | A final name, agreed with ZapFast's author, then the bundle identifier, targets and package names to match. |
| 📋 | Contributing guide and issue templates. |
| ✅ | No signing team in `project.yml`: `make run TEAM=…` or `ZAPFAST_TEAM` supplies yours. |
| 📋 | Publish under the fork's own repository and remote, with upstream kept as `upstream`. |
| 📋 | Make `Scripts/sync-upstream.sh` follow the linear-history policy instead of creating merge commits. |
| 📋 | Replace the private AppKit selector still used for the window's edge effect with public API, or document why it stays. |

## 2. Next: first signed release

Goal: a download that installs on a clean Mac without building from source.

| Status | Item |
|---|---|
| ⛔ | **Resolve the dependency license question.** `wacore-libsignal` (inside whatsapp-rust) declares MIT but carries Signal's AGPL-3.0 headers. Ask upstream for clarification, then record the decision in `macos/release-license-review.json`. The release gate stays closed until then. |
| 📋 | Review the dependencies whose packaged sources lack full license texts. |
| 📋 | Run the hosted CI workflow end to end, including the native build and all test suites. |
| 📋 | Developer ID signing and Apple notarization, rehearsed with real credentials. |
| 📋 | Install and run on a second, clean Mac. Test on macOS 15 and macOS 26, not only on the development system. |
| 📋 | **Run on an Intel Mac.** The Intel slice is built and validated, but nobody has run it yet. |
| 📋 | **Automatic updates** for the native app: signed update checks and installation, comparable to upstream's updater. |
| 📋 | Versioned release notes and a changelog. |

## 3. Calls

Calls are implemented in development builds (`make run CALLS=1`) and kept out of public
releases until they are proven on real devices. They will ship first as an opt-in
**experimental** feature.

**Working in development builds**
- One-to-one voice calls, incoming and outgoing, with the Mac's echo cancellation.
- One-to-one video calls (H.264, 720p at 20 fps), with switching from voice to video.
- Group voice calls; a group video call can be joined with voice.
- One waiting call during an active one, with Decline or End & Accept.
- Call history among a chat's messages, stored encrypted per account.
- App lock hides call video and turns the camera off.

**Before release (📋)**
- Live tests with Android and iPhone peers, incoming and outgoing.
- Audio routes: built-in, wired, Bluetooth, and switching during a call.
- Camera unplugged or busy, microphone permission denied, sleep and wake.
- Packet loss, low bandwidth and slow decoding.
- Calls on two linked accounts at the same time.
- Group calls with three or more people joining and leaving.
- Expand automated test coverage of the call module.

**Later (🔭)**
- Group video calls.
- Call links and joining from a link.
- Screen sharing (the protocol library supports only the signalling today).
- Hold and transfer depend on support in the protocol library.

## 4. Performance and stability

Results from the October 2026 audit that are not closed yet.

| Status | Item |
|---|---|
| 📋 | **Controlled benchmark against the official WhatsApp app.** Same Mac and display, the same chat sizes, cold and warm launch, chat opening, scrolling, resizing, memory, CPU and energy, at least three alternating runs each. Publish the method and the raw results. |
| 📋 | Move the Keychain and database opening at launch, and the waits at shutdown, off the main thread. |
| 📋 | Very large chats: reduce the remaining AppKit layout and display work during wide-window resizing and live updates. |
| 📋 | Draw the remaining SwiftUI message rows (polls, locations, contacts, business cards, sticker packs) in the same Core Animation cell as other messages. |
| 📋 | Cheaper first update when a message arrives in a chat that then moves to the top of the list. |
| 📋 | Stream long audio and recordings instead of holding them fully in memory. |
| 📋 | Remove periodic timers from the idle path so a quiet app does no work. |
| 📋 | Bound the event queue between the engine and the interface. |
| 📋 | Long-session checks: overnight memory, many chats opened and closed, energy use while idle and in the background. |

## 5. Features

Ordered roughly by how often people need them. Items marked ⛔ wait for the protocol
library.

**Groups and contacts**
- 📋 Create groups.
- 📋 Manage members and admins, group description, invite links and join requests.
- 📋 Block and unblock contacts.

**Messaging**
- 📋 Schedule a message to send later (kept locally until it is sent).
- 📋 Send your current or live location.
- 🔭 On-device translation and voice message transcription with Apple's frameworks, for the
  languages they support.

**Status, channels and communities**
- 📋 View status updates.
- 🔭 Post status updates.
- 🔭 Post to channels you administer.
- 🔭 Communities.

**Data**
- 📋 Encrypted backup and restore of the local archive, with a key you control.
- ⛔ Sync labels, chat lock settings and contact names for privacy-id chats with the phone.
  The library does not process these sync actions yet.
- ⛔ Request full history on demand. Depends on the library and on what the phone sends.

**Personalisation**
- 📋 Custom colour palettes from JSON files, as upstream supports.

## 6. Localization and accessibility

| Status | Item |
|---|---|
| ✅ | Every interface string in one string catalog, extracted from the code by the compiler. |
| ✅ | **Russian.** |
| 📋 | **Uzbek** (Latin) for the whole interface. Today only the in-chat search is translated. |
| 📋 | The languages upstream already ships: German, Spanish, French, Indonesian, Italian, Portuguese, Turkish, Chinese. |
| 📋 | A review of the Russian translation by native speakers. |
| 📋 | A full VoiceOver pass over Settings, the media editor and the viewer. |
| 📋 | Right-to-left layout checks for Arabic, Hebrew and Persian chats. |

## 7. Upstream and library work

Changes that belong in other projects. They are proposed there rather than kept in this
fork.

**ZapFast (upstream)**
- Offer the fork's engine additions: document page previews, Lottie stickers, albums and
  HD copies, the reason a media download failed, addressing a direct chat by its privacy
  id, and the hook that hands the WhatsApp client to an embedder.
- Keep following upstream releases and merging them promptly.

**whatsapp-rust**
- Clarify and fix the libsignal license metadata.
- Handle more app-state sync actions (labels, chat lock, contact names, status privacy).
- Automatic recovery when WhatsApp rejects an old client version.
- Faster connection: today about 3.6 seconds, partly spent on a failed settings recovery.
- Call quality features: bandwidth estimation, congestion control and loss recovery.

## 8. Not planned

These conflict with the project's boundaries or with how linked devices work.

- Registering a new WhatsApp account, changing a number, or deleting an account. A linked
  device cannot do these.
- Two-step verification setup and unlinking other devices.
- Uploading your address book.
- Telemetry, analytics, or any server of the project's own.
- A browser engine or web view for the interface.
- macOS 14 or earlier.

## 9. Done

Highlights of the work so far. The full record is in `git log`.

- ✅ Native SwiftUI and AppKit interface over the ZapFast engine.
- ✅ Every common message type, reactions, replies, edits, forwarding, polls, business
  messages, stickers including Lottie, GIFs, voice messages.
- ✅ Media editor and viewer, Share extension, drag and drop.
- ✅ In-chat search with highlighting, filters, calendar and multi-script matching.
- ✅ Several accounts in one window with separate data.
- ✅ App lock with Touch ID, chat lock, encrypted archive with a Keychain key.
- ✅ Chat export, history and media requests to the phone.
- ✅ Performance rebuild: virtualized lists, drawn bubbles, off-main layout, bounded memory.
- ✅ Engine builds without the egui interface.
- ✅ October 2026 audit: privacy, memory and correctness findings fixed with regression
  tests; native CI; dependency license inventory bundled in the app.
- ✅ Calls separated behind a build flag, universal (Apple silicon and Intel) builds, and a
  Russian interface.
