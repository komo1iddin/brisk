import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The chat's context menu, also offered by the conversation's menu.
public struct ChatActions: View {
    let chat: ChatSummary
    let model: AppModel

    public init(chat: ChatSummary, model: AppModel) {
        self.chat = chat
        self.model = model
    }

    public var body: some View {
        Button("Chat Info", systemImage: "info.circle") {
            if !model.isOpen(chat.id) { model.selectedChatID = chat.id }
            model.showInfo(in: chat.id)
        }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            model.openChatWindow(chat.id)
        }
        Divider()

        if chat.looksUnread {
            Button("Mark as Read", systemImage: "checkmark.circle") { model.markRead(chat.id) }
        } else {
            Button("Mark as Unread", systemImage: "circle.fill") { model.markUnread(chat.id) }
        }

        Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
            model.setPinned(!chat.pinned, chat: chat.id)
        }
        .disabled(!chat.pinned && model.chats.pinnedCount >= Int(model.session.pinLimit))

        if !chat.isChannel {
            Button(
                chat.favorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: chat.favorite ? "star.slash" : "star"
            ) {
                model.setFavorite(!chat.favorite, chat: chat.id)
            }
        }

        Menu("Labels", systemImage: "tag") {
            ForEach(model.chats.labels, id: \.id) { label in
                Toggle(isOn: Binding(
                    get: { chat.labels.contains(label.id) },
                    set: { _ in model.toggleLabel(label.id, on: chat) }
                )) {
                    Label {
                        Text(verbatim: label.name)
                    } icon: {
                        ColorSwatch.image(hex: label.colorHex)
                    }
                }
            }
            if !model.chats.labels.isEmpty { Divider() }
            Button("Manage Labels…") { model.labelsManagerShown = true }
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

        ChatSoundMenu(chat: chat, model: model)

        Button("Chat Theme…", systemImage: "paintpalette") { model.themeEditorChat = chat.id }

        Divider()

        if chat.locked {
            Button("Unlock Chat", systemImage: "lock.open") { model.setLocked(false, chat: chat.id) }
        } else {
            Button("Lock Chat…", systemImage: "lock") { model.confirmLock(chat.id) }
        }

        Button(
            chat.archived ? "Unarchive" : "Archive",
            systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox"
        ) {
            model.setArchived(!chat.archived, chat: chat.id)
        }

        // Reads this Mac's archive only, so it works offline.
        Button("Export Chat…", systemImage: "arrow.down.doc") { model.requestExport(chat.id) }
            .disabled(model.exportingChat != nil)

        // Both reach the phone first, so they wait for a connection.
        Button("Clear Chat…", systemImage: "eraser") { model.confirmClear(chat.id) }
            .disabled(!model.canClearOrDeleteChats)
        Button("Delete Chat…", systemImage: "trash", role: .destructive) { model.confirmDelete(chat.id) }
            .disabled(!model.canClearOrDeleteChats)
    }

    private func mute(hours: Int) {
        let until = Int64(Date.now.addingTimeInterval(TimeInterval(hours * 3600)).timeIntervalSince1970)
        model.setMuted(until: until, chat: chat.id)
    }
}
