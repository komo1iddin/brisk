import SwiftUI
import ZapFastBridge
import ZapFastCore

extension View {
    /// Asks before clearing or deleting a chat, in upstream's words: both
    /// reach the phone and cannot be undone.
    public func chatConfirmationAlert(model: AppModel) -> some View {
        modifier(ChatConfirmationAlert(model: model))
    }
}

private struct ChatConfirmationAlert: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        let confirmation = model.chatConfirmation
        content.alert(
            title(confirmation),
            isPresented: Binding(
                get: { model.chatConfirmation != nil },
                set: { if !$0 { model.chatConfirmation = nil } }
            ),
            presenting: confirmation
        ) { confirmation in
            switch confirmation.action {
            case .clear:
                Button("Clear Chat", role: .destructive) { model.perform(confirmation) }
            case .delete:
                Button("Delete Chat", role: .destructive) { model.perform(confirmation) }
            case .lock:
                Button("Lock Chat") { model.perform(confirmation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(message(confirmation))
        }
    }

    private func title(_ confirmation: ChatConfirmation?) -> Text {
        switch confirmation?.action {
        case .delete: Text("Delete this chat?")
        case .lock: Text("Lock this chat?")
        case .clear, nil: Text("Clear this chat?")
        }
    }

    private func message(_ confirmation: ChatConfirmation) -> String {
        let name = model.chats.chat(confirmation.chat).map(model.chats.title(for:))
            ?? String(localized: "this chat")
        switch confirmation.action {
        case .clear:
            return String(localized: "This clears every message in your chat with \(name), including downloaded media, on this Mac and on your phone. The chat itself stays. It can't be undone.")
        case .delete:
            return String(localized: "This deletes your chat with \(name), including all messages, on this Mac and on your phone. It can't be undone.")
        case .lock:
            return String(localized: "This moves the chat to Locked Chats, hiding it from the chat list, search, unread badges and notifications. The lock also syncs to your phone. Open Locked Chats with a separate local ZapFast code to read it. Sending from locked chats isn't supported yet.")
        }
    }
}
