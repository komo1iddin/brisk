import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZapFastCore

extension View {
    /// Asks how to export a chat, then where to put the file, as WhatsApp's
    /// own apps do: with the chat's media or without it.
    public func chatExportDialog(model: AppModel) -> some View {
        modifier(ChatExportDialog(model: model))
    }
}

private struct ChatExportDialog: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Export Chat",
            isPresented: Binding(
                get: { model.exportRequest != nil },
                set: { if !$0 { model.exportRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.exportRequest
        ) { request in
            Button("Attach Media") { choose(request.chat, withMedia: true) }
            Button("Without Media") { choose(request.chat, withMedia: false) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(message(request.chat))
        }
    }

    private func name(of chat: String) -> String {
        model.chats.chat(chat).map(model.chats.title(for:)) ?? String(localized: "this chat")
    }

    private func message(_ chat: String) -> String {
        String(localized: "Your chat with \(name(of: chat)) is saved as a web page you can read in a browser, in a new folder. Media goes into folders beside it, but only what this Mac has downloaded. Only messages stored on this Mac are included.")
    }

    /// Asks where the folder goes, then exports and opens the conversation.
    private func choose(_ chat: String, withMedia: Bool) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export Chat")
        panel.message = String(localized: "Choose where to put the folder “\(ChatExport.suggestedFolderName(chat: name(of: chat)))”.")
        panel.prompt = String(localized: "Export Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            model.exportChat(chat, includeMedia: withMedia, into: parent) { result in
                if case .success(let summary) = result {
                    NSWorkspace.shared.open(summary.page)
                }
            }
        }
    }
}
