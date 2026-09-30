import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

/// A message's context menu.
struct MessageActions: View {
    let message: MessageRecord
    let model: AppModel

    var body: some View {
        if isLive {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: message) }

            Menu("React", systemImage: "face.smiling") {
                ForEach(QuickReactions.emoji, id: \.self) { emoji in
                    Button(emoji) { model.react(emoji, to: message) }
                }
                if let mine = message.reactions.first(where: \.fromMe) {
                    Divider()
                    Button("Remove \(mine.emoji)") { model.react("", to: message) }
                }
            }
        }

        if model.canForward(message) {
            Button("Forward…", systemImage: "arrowshape.turn.up.right") { model.forward(message) }
        }

        if model.canEdit(message) {
            Button("Edit", systemImage: "pencil") { model.startEditing(message) }
        }

        if let text = copyableText {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        if model.canSelect(message) {
            Button("Select", systemImage: "checkmark.circle") { model.select(message) }
        }

        if model.canShowInfo(message) {
            Button("Info", systemImage: "info.circle") { model.showInfo(message) }
        }

        if message.content.media != nil {
            if let url = message.mediaURL {
                Button("Quick Look", systemImage: "eye") { QuickLook.shared.show([url]) }
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Save As…", systemImage: "square.and.arrow.down") {
                    AttachmentSaving.saveCopy(of: url, named: suggestedName(for: url))
                }
                if isPicture {
                    Button("Copy Image", systemImage: "photo.on.rectangle") {
                        AttachmentSaving.copyImage(at: url)
                    }
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.download(message) }
            }
        }

        Divider()

        Button("Delete for Me", systemImage: "trash", role: .destructive) { model.deleteForMe(message) }
        if model.canRevoke(message) {
            Button("Delete for Everyone", systemImage: "trash", role: .destructive) {
                model.deleteForEveryone(message)
            }
        }
    }

    private var isPicture: Bool {
        switch message.content {
        case .image, .sticker: true
        default: false
        }
    }

    /// A document keeps the name it was sent with; other media the file's.
    private func suggestedName(for url: URL) -> String {
        if case let .document(_, fileName, _, _) = message.content, !fileName.isEmpty { return fileName }
        return url.lastPathComponent
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
