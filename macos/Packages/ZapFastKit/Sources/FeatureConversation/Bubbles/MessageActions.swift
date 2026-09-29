import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

/// A message's context menu.
struct MessageActions: View {
    let message: MessageRecord
    let model: AppModel

    private static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        if isLive {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: message) }

            Menu("React", systemImage: "face.smiling") {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) { model.react(emoji, to: message) }
                }
                if let mine = message.reactions.first(where: \.fromMe) {
                    Divider()
                    Button("Remove \(mine.emoji)") { model.react("", to: message) }
                }
            }
        }

        if let text = copyableText {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        if message.content.media != nil {
            if let url = message.mediaURL {
                Button("Quick Look", systemImage: "eye") { QuickLook.shared.show([url]) }
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.download(message) }
            }
        }

        Divider()

        Button("Delete for Me", systemImage: "trash", role: .destructive) { model.deleteForMe(message) }
        if message.fromMe, isLive {
            Button("Delete for Everyone", systemImage: "trash", role: .destructive) {
                model.deleteForEveryone(message)
            }
        }
    }

    private var isLive: Bool {
        if case .revoked = message.content { false } else { true }
    }

    private var copyableText: String? {
        switch message.content {
        case .text(let text, _), .interactive(let text, _): text
        case .image(let caption, _), .video(let caption, _, _, _, _), .document(_, _, let caption, _): caption
        default: nil
        }
    }
}
