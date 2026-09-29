import SwiftUI
import ZapFastBridge
import ZapFastCore

/// The chat's context menu, also offered by the conversation's menu.
public struct ChatActions: View {
    let chat: ChatSummary
    let model: AppModel

    public init(chat: ChatSummary, model: AppModel) {
        self.chat = chat
        self.model = model
    }

    public var body: some View {
        if chat.looksUnread {
            Button("Mark as Read", systemImage: "checkmark.circle") { model.markRead(chat.id) }
        } else {
            Button("Mark as Unread", systemImage: "circle.fill") { model.markUnread(chat.id) }
        }

        Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
            model.setPinned(!chat.pinned, chat: chat.id)
        }
        .disabled(!chat.pinned && pinnedCount >= Int(model.session.pinLimit))

        if !chat.isChannel {
            Button(
                chat.favorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: chat.favorite ? "star.slash" : "star"
            ) {
                model.setFavorite(!chat.favorite, chat: chat.id)
            }
        }

        Menu("Mute", systemImage: "bell.slash") {
            if model.chats.isMuted(chat) {
                Button("Unmute") { model.setMuted(until: nil, chat: chat.id) }
                Divider()
            }
            Button("For 8 Hours") { mute(hours: 8) }
            Button("For 1 Week") { mute(hours: 24 * 7) }
            Button("Always") { model.setMuted(until: 0, chat: chat.id) }
        }

        Divider()

        Button(
            chat.archived ? "Unarchive" : "Archive",
            systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox"
        ) {
            model.setArchived(!chat.archived, chat: chat.id)
        }
    }

    private var pinnedCount: Int {
        model.chats.chats.values.count(where: \.pinned)
    }

    private func mute(hours: Int) {
        let until = Int64(Date.now.addingTimeInterval(TimeInterval(hours * 3600)).timeIntervalSince1970)
        model.setMuted(until: until, chat: chat.id)
    }
}
