---
title: Native macOS privacy
---

# Native macOS privacy

The native SwiftUI/AppKit interface lives under `macos/`. Its protocol and
encrypted archive come from the ZapFast engine.

Location messages display only the preview supplied by the sender. Showing
or scrolling past a location does not request a map from a third party.
If the preview is missing or unreadable, the location keeps a plain background
and its label. Clicking the message opens Apple Maps with its coordinates.
Copy Coordinates copies locally.

The app lock hides both sides of a video call and turns off the local camera.
Existing call audio may continue and incoming calls can be answered with
voice while locked. Unlocking does not turn the camera back on. Video
requires an explicit camera action after unlocking.

Native media previews use account/chat namespaces and content fingerprints.
Lottie stickers are unpacked by their full source path and content hash into
`.lottie-cache` beside the downloaded sticker, within the account's folder.
Removing that account removes these derived files too. The old shared
`Lottie/<filename>` cache is no longer read. A removed source file cannot be
reopened through its derived cache. Old shared cache files can be removed
manually after quitting the app; they contain no archive history.
