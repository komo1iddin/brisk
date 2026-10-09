import SwiftUI
import ZapFastBridge
import ZapFastCore

extension View {
    /// Asks before clearing or deleting a chat, in upstream's words: both
    /// reach the phone and cannot be undone.
    public func chatConfirmationAlert(model: AppModel) -> some View {
        modifier(ChatConfirmationAlert(model: model))
            .modifier(MessageDeletionAlert(model: model))
    }
}

/// Asks before deleting one message, in upstream's words. Return does not
/// confirm: a stray key must not destroy a message.
private struct MessageDeletionAlert: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        let deletion = model.messageDeletion
        content.alert(
            deletion?.forEveryone == true ? Text("Delete for everyone?") : Text("Delete for me?"),
            isPresented: Binding(
                get: { model.messageDeletion != nil },
                set: { if !$0 { model.messageDeletion = nil } }
            ),
            presenting: deletion
        ) { deletion in
            Button("Delete", role: .destructive) { model.performDeletion(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.forEveryone
                ? "Everyone in this chat will see \"This message was deleted\" instead. It can't be undone."
                : "This removes the message from your phone and linked devices. Other people keep their copy. Connect to WhatsApp to delete it. It can't be undone.")
        }
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
            case .leave:
                let chat = model.chats.chat(confirmation.chat)
                Button(chat?.isChannel == true ? "Leave Channel" : "Leave Group", role: .destructive) {
                    model.perform(confirmation)
                }
                if let chat, !chat.archived {
                    Button(chat.isChannel ? "Leave Channel and Archive" : "Leave Group and Archive", role: .destructive) {
                        model.chatConfirmation = nil
                        model.leaveGroup(chat, archive: true)
                    }
                }
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
        case .leave:
            model.chats.chat(confirmation?.chat ?? "")?.isChannel == true
                ? Text("Leave this channel?") : Text("Leave this group?")
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
        case .leave:
            return String(localized: "You will not receive new messages. The local history stays on this computer.")
        case .lock:
            return String(localized: "This moves the chat to Locked Chats, hiding it from the chat list, search, unread badges and notifications. The lock also syncs to your phone. Open Locked Chats with a separate local ZapFast code to read it. Sending from locked chats isn't supported yet.")
        }
    }
}
