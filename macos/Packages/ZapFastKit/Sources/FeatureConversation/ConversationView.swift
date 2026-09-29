import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// An open chat: the timeline under the title bar, and the composer.
public struct ConversationView: View {
    private let chatID: String
    @Bindable private var model: AppModel

    public init(chatID: String, model: AppModel) {
        self.chatID = chatID
        self.model = model
    }

    public var body: some View {
        let chat = model.chats.chat(chatID)
        let conversation = model.conversations.conversation(chatID)

        MessageTimeline(
            chatID: chatID,
            rows: TimelineRow.build(conversation.messages),
            chat: chat,
            model: model,
            jump: model.jump,
            onReachTop: { model.loadOlder(in: chatID) }
        )
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let chat, !canSend(chat) {
                ReadOnlyBar(chat: chat)
            } else {
                ComposerBar(chatID: chatID, model: model)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, chat.map(canSend) ?? true else { return false }
            model.sendFiles(files, in: chatID)
            return true
        }
        .navigationTitle(chat.map(model.chats.title(for:)) ?? "")
        .navigationSubtitle(subtitle(chat))
        .sheet(item: forwarding) { request in
            ForwardSheet(request: request, model: model)
        }
        .inspector(isPresented: searchPresented) {
            Group {
                if let search = model.search.chat, search.chat == chatID {
                    ChatSearchPanel(search: search, model: model)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button("Search in Chat", systemImage: "magnifyingglass") {
                    if searchPresented.wrappedValue {
                        model.closeChatSearch()
                    } else {
                        model.openChatSearch()
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

    private var searchPresented: Binding<Bool> {
        Binding(
            get: { model.search.chat?.chat == chatID },
            set: { presented in
                if presented { model.openChatSearch() } else { model.closeChatSearch() }
            }
        )
    }

    private func canSend(_ chat: ChatSummary) -> Bool {
        !chat.left && !(chat.readOnly && !chat.admin) && !(chat.isChannel && !chat.admin)
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
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(Metrics.m)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }

    private var message: LocalizedStringKey {
        if chat.left { return "You're no longer a participant." }
        if chat.isChannel { return "Only channel admins can post." }
        return "Only admins can send messages."
    }
}
