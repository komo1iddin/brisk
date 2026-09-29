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
            Button(confirmation.action == .clear ? "Clear Chat" : "Delete Chat", role: .destructive) {
                model.perform(confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(message(confirmation))
        }
    }

    private func title(_ confirmation: ChatConfirmation?) -> Text {
        confirmation?.action == .delete ? Text("Delete this chat?") : Text("Clear this chat?")
    }

    private func message(_ confirmation: ChatConfirmation) -> String {
        let name = model.chats.chat(confirmation.chat).map(model.chats.title(for:))
            ?? String(localized: "this chat")
        switch confirmation.action {
        case .clear:
            return String(localized: "This clears every message in your chat with \(name), including downloaded media, on this Mac and on your phone. The chat itself stays. It can't be undone.")
        case .delete:
            return String(localized: "This deletes your chat with \(name), including all messages, on this Mac and on your phone. It can't be undone.")
        }
    }
}
