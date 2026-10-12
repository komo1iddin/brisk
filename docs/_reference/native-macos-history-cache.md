# Native macOS loaded history cache

Each conversation cache and each open native pane retains at most 1,200
message records and 16 MiB of conservatively estimated record payload. The
estimate includes nested strings and binary fields such as thumbnails, plus
storage headroom. A single oversized message is retained so it remains
readable. This exception is reported in the store's accounting.

When a window reaches the row budget it trims to 900 records, leaving room
for arrivals and paging. It keeps the visible message when the reader is
away from the newest message. The opposite edge becomes available from the
encrypted archive again. Scrolling near either edge reads another page of
60 messages. The newest-message button loads the newest page directly.
Search and quoted-message jumps load the target with up to 60 messages on
either side, instead of loading the entire gap to the current page.
Boundaries use timestamp, phone history order and archive row order, so
messages sent in the same second are not skipped.

Each pane owns its own history window. Opening the same chat in two windows
allows independent reading positions. Live deliveries update a pane's
loaded records; a pane with archived newer messages waits for forward paging
instead of appending distant live messages across a gap. Failed reads keep
the current window and clear loading state. Stale replies, closed panes,
chat clearing and unlinking cannot restore retired windows.

Selection keeps IDs, order and capabilities rather than copies of message
bodies. Copy, Share and Forward can read evicted selections from this
account's archive. Missing records are omitted, reads run off the main
thread, and a cancelled selection or app lock prevents a pending result from
being presented. Explicit copying/sharing may allocate the requested output,
which is separate from the normal history cache budget.
Shift-click across an evicted selection anchor reads the explicit range in
pages and keeps only IDs, order and capabilities. A newer range request wins
over an older one; cancelling selection retires pending range reads.

Inactive loaded history is kept for at most eight chats and 12,000 total
message rows per account. Least recently used chats are evicted first.
Eviction resets paging flags; reopening requests the newest archive page.
macOS memory-pressure warnings remove eligible inactive conversations. Open
panes and running history requests remain protected from whole-chat eviction.
The encrypted archive, downloaded files, drafts and reply/edit state are
preserved. Account folders and readers remain separate.

Loaded snapshots share blocks of 256 records. A receipt, reaction, download
or append copies the affected block rather than every message. Ordinary
updates account for only changed records. Timeline layouts and hosted row
heights are pruned to the current window, so traversing an archive does not
leave old text layouts retained indefinitely.

A width-only resize keeps the vertical position without forcing a nested
layout pass. Narrower bubble widths reflow on the background layout scheduler
and restore the reading anchor. Live resize defers that reflow until the drag
ends. Height and composer-inset changes preserve the bottom when following
new messages. The composer's fading blur uses an AppKit material and layer
mask, avoiding a full-width SwiftUI material layout during resize.

These limits bound retained message payloads, not total process memory.
SQLite/FFI batches, decoded media, view layers, active jobs, explicit action
outputs and each additional open pane have their own lifetimes. Retained
snapshots can temporarily overlap during an update. Archive contents are
never deleted to meet the RAM budget.
