import FeatureConversation
import SwiftUI
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// One chat in a window of its own. It shows nothing while the app lock
/// is closed, a locked chat only while Locked Chats is open, and closes
/// its content when the chat is gone.
struct ChatWindow: View {
    let chatID: String
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.appLock.isLocked {
                ContentUnavailableView(
                    "ZapFast Is Locked",
                    systemImage: "lock.fill",
                    description: Text("Unlock ZapFast in its main window.")
                )
            } else if let chat = model.chats.chat(chatID), !chat.locked || model.lockedChats.isOpen {
                NavigationStack {
                    ConversationView(chatID: chatID, model: model)
                }
                .onAppear { model.chatWindowAppeared(chatID) }
                .onDisappear { model.chatWindowDisappeared(chatID) }
            } else {
                ContentUnavailableView("This chat is not available", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .tint(model.chatTheme(for: chatID).accent)
        .chatConfirmationAlert(model: model)
        // Notices show once, in the main window.
        .opensInviteLinks(model: model)
    }
}
