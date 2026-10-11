# Native macOS loaded history cache

The native model keeps inactive loaded history for at most eight chats and
12,000 total message rows per account. Least recently used chats are evicted
first when either limit is exceeded. Eviction releases loaded message copies
and resets their paging flags; opening that chat requests its newest archive
page again. The encrypted archive and downloaded files are preserved.

The main pane of the account on screen and separate chat windows are protected.
Their selection, jump target and reading anchor are unchanged by cache pruning.
An account hidden by switching accounts loses the main-pane protection. When
shown again its selected chat reloads if evicted. Requests already fetching
phone history or paging the archive stay protected until their response.

macOS memory-pressure warnings remove every eligible inactive conversation.
Composer drafts, reply/edit records and the archive remain separate from this
cache. An evicted inactive chat reopens on the newest page, as a cold chat does.

These are row/count limits for inactive model copies, not a byte limit or a
cap on history deliberately loaded in an open pane. A large active chat and
its timeline items still scale with its loaded row count. Further active-page
virtualization needs paging in both directions while preserving the reader's
position; the audit keeps that part of F10 open.
