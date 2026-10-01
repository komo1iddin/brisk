import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The sidebar while searching finds messages too: the chats that match,
/// then the messages, in SwiftUI's sidebar list.
struct SidebarSearchList: View {
    let chats: [ChatSummary]
    let hits: [MessageRecord]
    let query: String
    /// The chat the arrow keys reached in the search field: marked here,
    /// not opened.
    let cursor: String?
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: opening) {
                if !chats.isEmpty {
                    Section("Chats") {
                        ForEach(chats) { chat in
                            ChatRow(chat: chat, model: model)
                                .tag(chat.id)
                        }
                    }
                }
                Section("Messages") {
                    ForEach(hits, id: \.id) { hit in
                        MessageHitRow(message: hit, query: query, model: model)
                            .selectionDisabled()
                    }
                }
            }
            // One menu for the list, made when asked for, rather than a menu
            // modifier on each row.
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let chat = model.chats.chat(id) {
                    ChatActions(chat: chat, model: model)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: cursor) { _, reached in
                if let reached { proxy.scrollTo(reached) }
            }
        }
    }

    /// The chat the keys reached, else the open one; a click opens.
    private var opening: Binding<String?> {
        Binding(
            get: { cursor ?? model.selectedChatID },
            set: { id in
                if let id { model.keepUnread(id) }
                model.selectedChatID = id
            }
        )
    }
}

extension ChatFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .direct: "Private"
        case .favorites: "Favorites"
        case .groups: "Groups"
        case .channels: "Channels"
        }
    }

    /// The same, for AppKit menus.
    var name: String {
        switch self {
        case .all: String(localized: "All")
        case .unread: String(localized: "Unread")
        case .direct: String(localized: "Private")
        case .favorites: String(localized: "Favorites")
        case .groups: String(localized: "Groups")
        case .channels: String(localized: "Channels")
        }
    }
}

// MARK: - Rows

/// Archived and Locked Chats, above the chats.
struct FolderRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let count: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Metrics.m) {
                Image(systemName: systemImage)
                    .frame(width: Metrics.rowAvatar)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let query: String
    let filter: ChatFilter
    let archived: Bool
    let locked: Bool
    let labeled: Bool

    var body: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if labeled {
            ContentUnavailableView(
                "No chats with this label",
                systemImage: "tag",
                description: Text("Add chats to it from their right-click menu.")
            )
        } else if locked {
            ContentUnavailableView("No locked chats", systemImage: "lock")
        } else if archived {
            ContentUnavailableView("No archived chats", systemImage: "archivebox")
        } else if filter != .all {
            ContentUnavailableView("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

/// History sync progress while the phone copies messages over.
struct SyncStatus: View {
    let session: SessionStore

    var body: some View {
        if session.isSyncing || isOffline {
            HStack(spacing: Metrics.s) {
                if session.isSyncing {
                    ProgressView().controlSize(.small)
                    if let percent = session.syncProgress {
                        Text("Syncing history… \(percent)%")
                    } else {
                        Text("Syncing history…")
                    }
                } else {
                    Image(systemName: "wifi.slash")
                    Text("Offline, reconnecting…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, Metrics.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var isOffline: Bool {
        if case .disconnected = session.link { true } else { false }
    }
}
