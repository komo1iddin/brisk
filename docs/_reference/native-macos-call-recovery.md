---
title: Native macOS call recovery
---

# Native macOS call recovery

One account owns call capture and playout at a time. If another account has
a call going, placing or answering a second call shows a notice asking you
to end the first. The incoming call stays ringing. Switching accounts keeps
the existing call going. Removing/unlinking an account releases its media
and invalidates pending permission responses, including a placed call whose
first interface callback has not arrived yet.
Reset releases a pending permission reservation immediately. Its eventual
answer cannot release or change the reservation of a later call.

Camera startup succeeds only after capture starts. If configuration fails,
the camera is interrupted, or capture stops unexpectedly, the camera turns
off and the call continues with voice. A notice explains the failure. Turn
the camera on explicitly to retry. A late failure from a previous camera
cannot turn off the camera of a replacement call. Stopped encoder and
microphone callbacks cannot send into a later call through the account's
shared bridge handle. If an audio-device change cannot restart the sound
engine, the app reports the failure and ends that call.

Received H.264 video holds at most eight pending access units and 4 MiB in
the interface queue; a single access unit over 1 MiB is dropped. There is one
drain job, with at most one additional unit being processed. Overflow drops
the dependent chain and waits for a keyframe. Renderer backpressure also
requires a fresh keyframe. Keyframe requests are limited to one per second
per stream; camera-side requests coalesce into the next captured frame.
These bounds exclude AVFoundation's decoder/output surfaces and the Rust
media queues. They are not a hard bound on total process memory.

Locking stops remote decoding and local camera capture. Existing audio can
continue. Unlocking resumes remote video; the local camera requires an
explicit action. Closing an account's call service disconnects its listener
and drops the renderer retention cycle.

Chat call history loads asynchronously on a serial queue belonging to its
account. Opening a chat may briefly show messages before its call rows arrive.
Reports received during the database read override the older snapshot.
Cancelled/account-reset reads cannot install a stale result.

Queue, permission, lock, account ownership and failure handling are tested
with synthetic records and mock capture configuration. Real network calls,
camera unplug/sleep and CoreAudio device changes still need live validation.

Apple documents [renderer queue readiness](https://developer.apple.com/documentation/avfoundation/avqueuedsamplebufferrendering/isreadyformoremediadata),
[blocking camera startup](https://developer.apple.com/documentation/avfoundation/avcapturesession/startrunning()),
and [camera runtime errors](https://developer.apple.com/documentation/avfoundation/avcapturesession/runtimeerrornotification).
