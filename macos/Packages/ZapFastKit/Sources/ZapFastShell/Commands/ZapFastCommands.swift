import SwiftUI
import ZapFastCore

/// Menu bar additions. Standard menus (Edit, Window, Help) come from the system.
struct ZapFastCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Chat") {
            Button("Mark as Read") {
                if let id = model.selectedChatID { model.markRead(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedChatID == nil)

            Button("Mark as Unread") {
                if let id = model.selectedChatID { model.markUnread(id) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.selectedChatID == nil)

            Divider()

            Button("Close Chat") { model.selectedChatID = nil }
                .disabled(model.selectedChatID == nil)
        }

        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find in Chat…") { model.openChatSearch() }
                    .keyboardShortcut("f")
                    .disabled(model.selectedChatID == nil)

                Button("Search All Chats") { model.focusSidebarSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button("Find Next") { model.stepChatSearch(older: true) }
                    .keyboardShortcut("g")
                    .disabled(!hasChatHits)

                Button("Find Previous") { model.stepChatSearch(older: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!hasChatHits)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Reconnect") { model.reconnect() }
                .disabled(model.session.isConnected)
        }
    }

    private var hasChatHits: Bool {
        model.search.chat.map { !$0.hits.isEmpty } ?? false
    }
}
