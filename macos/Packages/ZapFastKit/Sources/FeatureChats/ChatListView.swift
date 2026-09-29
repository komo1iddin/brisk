import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The sidebar: filter, search, the Archived entry, and the chats.
public struct ChatListView: View {
    @Bindable private var model: AppModel

    @State private var query = ""
    @State private var filter: ChatFilter = .all
    @State private var showingArchived = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let chats = model.chats.visibleChats(filter: filter, query: query, archived: showingArchived)
        List(selection: $model.selectedChatID) {
            if query.isEmpty {
                if !showingArchived, filter == .all, model.chats.archivedCount > 0 {
                    ArchivedRow(unread: model.chats.archivedUnread) { showingArchived = true }
                        .selectionDisabled()
                }
            }

            ForEach(chats) { chat in
                ChatRow(chat: chat, model: model)
                    .tag(chat.id)
                    .contextMenu { ChatActions(chat: chat, model: model) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search chats")
        .overlay {
            if chats.isEmpty {
                EmptyState(query: query, filter: filter, archived: showingArchived)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatus(session: model.session)
        }
        .navigationTitle(title)
        .toolbar {
            if showingArchived {
                ToolbarItem(placement: .navigation) {
                    Button("Back to Chats", systemImage: "chevron.backward") { showingArchived = false }
                }
            } else {
                ToolbarItem {
                    FilterMenu(selection: $filter)
                }
            }
        }
    }
}

extension ChatListView {
    private var title: Text {
        if showingArchived { return Text("Archived") }
        return filter == .all ? Text("Chats") : Text(filter.title)
    }
}

// MARK: - Filter

/// Mail-style filter button: filled while a filter is on.
private struct FilterMenu: View {
    @Binding var selection: ChatFilter

    var body: some View {
        Menu {
            Picker("Show", selection: $selection) {
                ForEach(ChatFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                "Filter",
                systemImage: selection == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help("Filter chats")
    }
}

extension ChatFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .favorites: "Favorites"
        case .groups: "Groups"
        case .channels: "Channels"
        }
    }
}

// MARK: - Rows

private struct ArchivedRow: View {
    let unread: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Metrics.m) {
                Image(systemName: "archivebox")
                    .frame(width: Metrics.rowAvatar)
                    .foregroundStyle(.secondary)
                Text("Archived")
                Spacer()
                if unread > 0 {
                    Text("\(unread)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyState: View {
    let query: String
    let filter: ChatFilter
    let archived: Bool

    var body: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if archived {
            ContentUnavailableView("No archived chats", systemImage: "archivebox")
        } else if filter != .all {
            ContentUnavailableView("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

/// History sync progress while the phone copies messages over.
private struct SyncStatus: View {
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
