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
    /// A label chosen in place of a built-in filter.
    @State private var label: String?
    @State private var showingArchived = false
    @FocusState private var searchFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let chats = model.chats.visibleChats(
            filter: filter, query: query, archived: showingArchived, label: label
        )
        let hits = messageHits
        List(selection: $model.selectedChatID) {
            if hits.isEmpty {
                if query.isEmpty, !showingArchived, filter == .all, label == nil, model.chats.archivedCount > 0 {
                    ArchivedRow(unread: model.chats.archivedUnread) { showingArchived = true }
                        .selectionDisabled()
                }
                chatRows(chats)
            } else {
                if !chats.isEmpty {
                    Section("Chats") { chatRows(chats) }
                }
                Section("Messages") {
                    ForEach(hits, id: \.id) { hit in
                        MessageHitRow(message: hit, query: query, model: model)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: query) { model.searchMessages(query) }
        .onChange(of: model.sidebarSearchRequests) { searchFocused = true }
        .overlay {
            if chats.isEmpty, hits.isEmpty {
                EmptyState(query: query, filter: filter, archived: showingArchived, labeled: label != nil)
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
                    FilterMenu(selection: $filter, label: $label, model: model)
                }
                ToolbarItem {
                    Button("New Chat", systemImage: "square.and.pencil") { model.newChatShown = true }
                        .help("Start a new chat (⌘N)")
                }
            }
        }
        .sheet(isPresented: $model.newChatShown) {
            NewChatSheet(model: model)
        }
        .sheet(isPresented: $model.labelsManagerShown) {
            LabelManagerSheet(model: model)
        }
        // A deleted label stops filtering.
        .onChange(of: model.chats.labels.map(\.id)) { _, ids in
            if let label, !ids.contains(label) { self.label = nil }
        }
    }
}

extension ChatListView {
    private func chatRows(_ chats: [ChatSummary]) -> some View {
        ForEach(chats) { chat in
            ChatRow(chat: chat, model: model)
                .tag(chat.id)
                .contextMenu { ChatActions(chat: chat, model: model) }
        }
    }

    /// Messages matching the search, once the archive has answered the
    /// query in the field rather than an earlier one.
    private var messageHits: [MessageRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.search.messageQuery == trimmed else { return [] }
        return model.search.messageHits
    }

    private var title: Text {
        if showingArchived { return Text("Archived") }
        if let label, let name = model.chats.labels.first(where: { $0.id == label })?.name {
            return Text(verbatim: name)
        }
        return filter == .all ? Text("Chats") : Text(filter.title)
    }
}

// MARK: - Filter

/// Mail-style filter button: filled while a filter is on. A label is one
/// more choice beside the built-in filters, as upstream's chips are.
private struct FilterMenu: View {
    @Binding var selection: ChatFilter
    @Binding var label: String?
    let model: AppModel

    var body: some View {
        Menu {
            Picker("Show", selection: builtIn) {
                ForEach(ChatFilter.allCases) { filter in
                    Text(filter.title).tag(Optional(filter))
                }
            }
            .pickerStyle(.inline)

            Section("Labels") {
                ForEach(model.chats.labels, id: \.id) { item in
                    Toggle(isOn: Binding(
                        get: { label == item.id },
                        set: { if $0 { label = item.id } else { label = nil; selection = .all } }
                    )) {
                        Label {
                            Text(verbatim: item.name)
                        } icon: {
                            ColorSwatch.image(hex: item.colorHex)
                        }
                    }
                }
                Button("Manage Labels…") { model.labelsManagerShown = true }
            }
        } label: {
            Label(
                "Filter",
                systemImage: selection == .all && label == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help("Filter chats")
    }

    /// The built-in filter, shown unchosen while a label filters instead.
    private var builtIn: Binding<ChatFilter?> {
        Binding(
            get: { label == nil ? selection : nil },
            set: { filter in
                label = nil
                if let filter { selection = filter }
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
