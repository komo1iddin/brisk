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
        let inLocked = model.lockedChats.isOpen
        ChatListContent(
            model: model,
            query: query,
            filter: filter,
            label: label,
            showingArchived: $showingArchived,
            inLocked: inLocked
        )
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: query) { model.searchMessages(query) }
        .onChange(of: keepsUnread(inLocked: inLocked), initial: true) { _, keeps in model.sidebarKeepsUnread = keeps }
        .onChange(of: filter) { model.forgetKeptUnread() }
        .onChange(of: label) { model.forgetKeptUnread() }
        .onChange(of: showingArchived) { model.forgetKeptUnread() }
        .onChange(of: model.sidebarSearchRequests) { searchFocused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatus(session: model.session)
        }
        .navigationTitle(title)
        .toolbar {
            if inLocked {
                ToolbarItem(placement: .navigation) {
                    Button("Lock and Go Back", systemImage: "chevron.backward") { model.closeLockedChats() }
                        .help("Lock these chats again and go back")
                }
            } else if showingArchived {
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
        .sheet(isPresented: $model.lockedChatsPrompt) {
            LockedChatsSheet(model: model)
        }
        .onChange(of: inLocked) { query = "" }
        // A deleted label stops filtering.
        .onChange(of: model.chats.labels.map(\.id)) { _, ids in
            if let label, !ids.contains(label) { self.label = nil }
        }
    }

    private func keepsUnread(inLocked: Bool) -> Bool {
        filter == .unread && label == nil && query.isEmpty && !showingArchived && !inLocked
    }

    private var title: Text {
        if model.lockedChats.isOpen { return Text("Locked Chats") }
        if showingArchived { return Text("Archived") }
        if let label, let name = model.chats.labels.first(where: { $0.id == label })?.name {
            return Text(verbatim: name)
        }
        return filter == .all ? Text("Chats") : Text(filter.title)
    }
}

/// The list itself, apart from the sidebar's toolbar, search field and
/// title: every chat that changes redraws this, and the toolbar's menus
/// were rebuilt with it when they shared a body.
private struct ChatListContent: View {
    @Bindable var model: AppModel
    let query: String
    let filter: ChatFilter
    let label: String?
    @Binding var showingArchived: Bool
    let inLocked: Bool

    var body: some View {
        let chats = inLocked
            ? model.chats.lockedChats(query: query)
            : model.chats.visibleChats(
                filter: filter, query: query, archived: showingArchived, label: label, kept: model.keptUnread
            )
        let hits = inLocked ? [] : messageHits
        Group {
            if hits.isEmpty, !Self.usesSwiftUIList {
                GeometryReader { proxy in
                    ChatTable(
                        rows: tableRows(chats),
                        selection: opening,
                        model: model,
                        topInset: proxy.safeAreaInsets.top
                    )
                    .ignoresSafeArea(edges: .top)
                }
            } else {
                list(chats: chats, hits: hits)
            }
        }
        // ⌃Tab and ⌃⇧Tab step through the chats as listed here.
        .onChange(of: chats.map(\.id), initial: true) { _, ids in model.sidebarOrder = ids }
        .overlay {
            if chats.isEmpty, hits.isEmpty {
                EmptyState(query: query, filter: filter, archived: showingArchived, locked: inLocked, labeled: label != nil)
            }
        }
    }

    /// `ZAPFAST_SWIFTUI_SIDEBAR=1` shows the earlier SwiftUI list, to compare
    /// the two side by side.
    private static let usesSwiftUIList = ProcessInfo.processInfo.environment["ZAPFAST_SWIFTUI_SIDEBAR"] != nil

    /// The folders above the chats, then the chats, for the table.
    private func tableRows(_ chats: [ChatSummary]) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        if query.isEmpty, !showingArchived, !inLocked, filter == .all, label == nil {
            if model.chats.lockedCount > 0 {
                rows.append(.folder(id: "locked", title: "Locked Chats", systemImage: "lock", count: nil) { [model] in
                    model.openLockedChats()
                })
            }
            if model.chats.archivedCount > 0 {
                let archived = $showingArchived
                rows.append(.folder(id: "archived", title: "Archived", systemImage: "archivebox", count: model.chats.archivedUnread) {
                    archived.wrappedValue = true
                })
            }
        }
        rows += chats.map(SidebarRow.chat)
        return rows
    }

    /// The SwiftUI list: search results, with their sections, and the
    /// comparison mode above.
    private func list(chats: [ChatSummary], hits: [MessageRecord]) -> some View {
        List(selection: opening) {
            if hits.isEmpty {
                if query.isEmpty, !showingArchived, !inLocked, filter == .all, label == nil {
                    if model.chats.lockedCount > 0 {
                        FolderRow(title: "Locked Chats", systemImage: "lock", count: nil) { model.openLockedChats() }
                            .selectionDisabled()
                    }
                    if model.chats.archivedCount > 0 {
                        FolderRow(title: "Archived", systemImage: "archivebox", count: model.chats.archivedUnread) {
                            showingArchived = true
                        }
                        .selectionDisabled()
                    }
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
        // One menu for the list, made when asked for, rather than a menu
        // modifier on each of hundreds of rows rebuilt with every change.
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let chat = model.chats.chat(id) {
                ChatActions(chat: chat, model: model)
            }
        }
        .listStyle(.sidebar)
    }

    /// A chat clicked in the list; one clicked in the Unread list stays
    /// there once read, so its row does not leave from under the pointer.
    private var opening: Binding<String?> {
        Binding(
            get: { model.selectedChatID },
            set: { id in
                if let id { model.keepUnread(id) }
                model.selectedChatID = id
            }
        )
    }

    private func chatRows(_ chats: [ChatSummary]) -> some View {
        ForEach(chats) { chat in
            ChatRow(chat: chat, model: model)
                .tag(chat.id)
        }
    }

    /// Messages matching the search, once the archive has answered the
    /// query in the field rather than an earlier one.
    private var messageHits: [MessageRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.search.messageQuery == trimmed else { return [] }
        return model.search.messageHits
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

            if !model.chats.channels.isEmpty {
                let muted = model.allChannelsMuted
                Button(
                    muted ? "Unmute All Channels" : "Mute All Channels",
                    systemImage: muted ? "bell" : "bell.slash"
                ) { model.muteAllChannels(!muted) }
            }

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

private struct EmptyState: View {
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
