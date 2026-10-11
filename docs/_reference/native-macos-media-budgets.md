# Native macOS animation resource budgets

The native interface decodes animated WebP/GIF files only while they play.
Two frame decoders may run at once across the process. Readers of the same
source and display size share one job. Leaving the sticker cancels that
reader; a job with no readers stops between frames.

A decode accepts at most 150 frames and retains at most 24 MiB of decoded
pixels. It reduces the thumbnail resolution before allocating frames to
fit that budget, up to 640 pixels per side. A file with more frames keeps
its still preview. The separate frame cache has limits of 12 animations
and 48 MiB of decoded pixels. These are pixel/cache budgets, not a promise
about the memory ImageIO or Core Animation uses internally.

Lottie `.was` extraction runs one job at a time. Before extraction it
checks the 64 MiB compressed file limit, 256 entry limit, 64 MiB aggregate
unpacked limit and 8 MiB limit per JSON file. Cancellation is checked
between entries. Unsupported or oversized files retain their local preview.
Lottie JSON parsing is serial, shares pending work for the same unpacked
file, and accepts at most 32 pending distinct animations. Its parsed-model
cache holds at most 24 entries with a 32 MiB cost limit. The cost is eight
times JSON bytes, an estimate rather than a measured model heap size.

Derived unpack folders remain scoped by source path and content. Pruning
keeps at most 64 inactive/current folders within a 256 MiB disk budget,
removing the oldest eligible folders first. Active views and pending
parsers retain leases on their image folders; those folders may temporarily
exceed the budget and are eligible at the next extraction after release.
Only recognized source/content hash folders in the derived cache are
eligible. Downloaded sources, the encrypted archive and unrelated files
are preserved. Account removal removes its derived folders with its cache.

These limits protect the native animation path; video and voice playback
have separate resource policies. Long audio/recording and live call
backpressure remain audit items.
