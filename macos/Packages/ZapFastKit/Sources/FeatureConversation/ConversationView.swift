import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// An open chat: the timeline under the title bar, and the composer.
public struct ConversationView: View {
    private let chatID: String
    @Bindable private var model: AppModel
    @State private var scrollState = TimelineController.ScrollState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(chatID: String, model: AppModel) {
        self.chatID = chatID
        self.model = model
    }

    public var body: some View {
        let chat = model.chats.chat(chatID)
        let conversation = model.conversations.conversation(chatID)
        let theme = model.chatTheme(for: chatID)

        MessageTimeline(
            chatID: chatID,
            rows: TimelineRow.build(conversation.messages, unread: model.unreadDivider),
            chat: chat,
            model: model,
            jump: model.jump,
            theme: theme,
            scrollRequest: model.timelineScroll,
            onReachTop: { model.loadOlder(in: chatID) },
            onScrollState: { scrollState = $0 }
        )
        .background { WallpaperView(theme.wallpaper).ignoresSafeArea() }
        // The table scrolls under the title bar; AppKit insets its content.
        .ignoresSafeArea(edges: .top)
        .overlay {
            if conversation.requested, conversation.messages.isEmpty, !conversation.fetchingPhone {
                ContentUnavailableView("No messages here yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .overlay(alignment: .top) {
            if conversation.loadingOlder || conversation.fetchingPhone {
                ProgressView()
                    .controlSize(.small)
                    .padding(Metrics.s)
                    .modifier(GlassCard())
                    .padding(.top, Metrics.s)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !scrollState.atBottom {
                NewestMessageButton(newBelow: scrollState.newBelow) { model.scrollTimeline(.bottom) }
                    .padding(Metrics.l)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.zf(reduceMotion), value: scrollState.atBottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selection = model.selection, selection.chat == chatID {
                SelectionBar(selection: selection, model: model)
            } else if let chat, !canSend(chat) {
                ReadOnlyBar(chat: chat)
            } else {
                ComposerBar(chatID: chatID, model: model)
            }
        }
        // Photos and videos about to go out, in a window over this one.
        .background {
            MediaEditorPresenter(
                chatID: chatID, model: model, isPresented: model.isEditingMedia(in: chatID), theme: theme
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, chat.map(canSend) ?? true else { return false }
            model.stage(files: files, in: chatID)
            return true
        }
        .environment(\.chatTheme, theme)
        .tint(theme.accent)
        .navigationTitle(chat.map(model.chats.title(for:)) ?? "")
        .navigationSubtitle(subtitle(chat))
        .sheet(item: forwarding) { request in
            ForwardSheet(request: request, model: model)
        }
        .sheet(item: pollResults) { key in
            PollResultsSheet(key: key, model: model)
        }
        .sheet(item: messageInfo) { key in
            MessageInfoSheet(key: key, model: model)
        }
        .sheet(item: stickerPack) { preview in
            StickerPackSheet(preview: preview, model: model)
        }
        .sheet(item: interactiveList) { request in
            InteractiveListSheet(request: request, model: model)
        }
        .inspector(isPresented: inspectorPresented) {
            Group {
                if let search = model.search.chat, search.chat == chatID {
                    ChatSearchPanel(search: search, model: model)
                } else if model.infoChat == chatID {
                    ChatInfoPanel(chatID: chatID, model: model)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button("Chat Info", systemImage: "info.circle") {
                    if model.infoChat == chatID { model.closeInfo() } else { model.showInfo(in: chatID) }
                }
                .help("Show chat info (⌘I)")
            }
            ToolbarItem {
                Button("Search in Chat", systemImage: "magnifyingglass") {
                    if model.search.chat?.chat == chatID {
                        model.closeChatSearch()
                    } else {
                        model.openChatSearch(in: chatID)
                    }
                }
                .help("Search in this chat (⌘F)")
            }
            if let chat {
                ToolbarItem {
                    Menu {
                        ChatActions(chat: chat, model: model)
                    } label: {
                        Label("Chat", systemImage: "ellipsis.circle")
                    }
                    .help("Chat actions")
                }
            }
        }
    }

    private var forwarding: Binding<ForwardRequest?> {
        Binding(
            get: { model.forwarding.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { if $0 == nil { model.cancelForward() } }
        )
    }

    private var pollResults: Binding<MessageKey?> {
        Binding(
            get: { model.pollResults.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.pollResults = $0 }
        )
    }

    private var stickerPack: Binding<StickerPackPreview?> {
        Binding(
            get: { model.stickerPackPreview.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.stickerPackPreview = $0 }
        )
    }

    private var interactiveList: Binding<InteractiveListRequest?> {
        Binding(
            get: { model.interactiveList.flatMap { $0.key.chat == chatID ? $0 : nil } },
            set: { model.interactiveList = $0 }
        )
    }

    private var messageInfo: Binding<MessageKey?> {
        Binding(
            get: { model.messageInfo.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.messageInfo = $0 }
        )
    }

    /// The inspector holds either the chat's search or its info.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.search.chat?.chat == chatID || model.infoChat == chatID },
            set: { presented in
                guard !presented else { return }
                model.closeChatSearch()
                model.closeInfo()
            }
        )
    }

    private func canSend(_ chat: ChatSummary) -> Bool {
        !chat.locked && !chat.left && !(chat.readOnly && !chat.admin) && !(chat.isChannel && !chat.admin)
    }

    /// Typing, presence, or group members, under the title.
    private func subtitle(_ chat: ChatSummary?) -> String {
        guard let chat else { return "" }
        if let senders = model.conversations.typing[chatID], !senders.isEmpty {
            if chat.kind == .group, let first = senders.first {
                return String(localized: "\(model.chats.personName(first, hint: nil)) is typing…")
            }
            return String(localized: "typing…")
        }
        switch chat.kind {
        case .group:
            return model.chats.participantNames(chat)
        case .broadcast:
            return chat.isChannel ? String(localized: "Channel") : String(localized: "Broadcast list")
        case .direct:
            if let presence = model.conversations.presence[chatID] {
                if presence.online { return String(localized: "online") }
                if let seen = presence.lastSeen { return DateText.lastSeen(seen) }
            }
            return chat.phone ?? ""
        }
    }
}

private struct ReadOnlyBar: View {
    let chat: ChatSummary

    var body: some View {
        if #available(macOS 26, *) {
            // Floating in glass over the chat, as the composer is.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Metrics.m)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, Metrics.s)
        } else {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Metrics.m)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }

    private var message: LocalizedStringKey {
        if chat.locked { return "Locked chats are read-only in ZapFast." }
        if chat.left { return "You're no longer a participant." }
        if chat.isChannel { return "Only channel admins can post." }
        return "Only admins can send messages."
    }
}

/// Floats over the timeline while older messages are being read and
/// scrolls back to the newest one, with a count of those that arrived.
private struct NewestMessageButton: View {
    let newBelow: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .modifier(FloatingSurface(Circle()))
        .overlay(alignment: .topTrailing) {
            if newBelow > 0 {
                Text(newBelow, format: .number)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.tint, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
        .help("Scroll to the newest message")
        .accessibilityLabel(newBelow > 0 ? Text("Newest message, \(newBelow) new") : Text("Newest message"))
    }
}

/// In place of the composer while messages are selected: how many, and
/// what can be done with them. Escape ends selecting.
private struct SelectionBar: View {
    let selection: MessageSelection
    let model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: Metrics.m) {
            Button {
                model.cancelSelection()
            } label: {
                Label("Cancel Selection", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .keyboardShortcut(.cancelAction)
            .help("Cancel selection (Esc)")

            Text("\(selection.ids.count) selected")
                .font(.body.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: selection.ids.count)

            Spacer()

            Button {
                confirmingDelete = true
            } label: {
                Label("Delete for Me", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .help("Delete for me")

            Button {
                model.forwardSelection()
            } label: {
                Label("Forward…", systemImage: "arrowshape.turn.up.right")
                    .padding(.horizontal, Metrics.xs)
                    .frame(height: 22)
            }
            .selectionButton(prominent: true)
            .disabled(model.forwardableSelection.isEmpty)
            .help("Forward the selected messages")
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
        .modifier(SelectionBarSurface())
        .confirmationDialog(
            Text("Delete \(selection.ids.count) messages for you?"),
            isPresented: $confirmingDelete
        ) {
            Button("Delete for Me", role: .destructive) { model.deleteSelectionForMe() }
        } message: {
            Text("They are removed from ZapFast on this Mac. Your phone and the chat keep them.")
        }
    }
}

private struct SelectionBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

private extension View {
    @ViewBuilder
    func selectionButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).controlSize(.large)
            } else {
                buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}
