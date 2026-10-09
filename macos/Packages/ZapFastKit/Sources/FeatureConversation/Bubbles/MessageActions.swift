import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

/// A message's context menu.
struct MessageActions: View {
    let message: MessageRecord
    let model: AppModel
    /// Whether React is a submenu here.
    var reactsInMenu = true

    /// In groups, most used first, a line between each: answering the
    /// message, then picking it, then what its content offers, then its
    /// file, the rare tools in a submenu, and deleting last.
    var body: some View {
        primary
        if hasManage {
            if hasPrimary { Divider() }
            manage
        }
        if hasContent {
            if hasPrimary || hasManage { Divider() }
            content
        }
        if message.content.media != nil {
            if hasPrimary || hasManage || hasContent { Divider() }
            file
        }
        if hasPrimary || hasManage || hasContent || message.content.media != nil { Divider() }
        more
        Divider()
        delete
    }

    // MARK: Groups

    private var hasPrimary: Bool {
        isLive || copyableText != nil || model.canForward(message) || model.canEdit(message)
    }

    /// Reply, copy, forward, edit: what a message is opened for.
    @ViewBuilder private var primary: some View {
        if isLive {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: message) }
        }

        // The drawn timeline floats the quick reactions above its menu
        // (`MenuReactionBar`); VoiceOver and the SwiftUI rows find them here.
        if isLive, reactsInMenu {
            Menu("React", systemImage: "face.smiling") {
                ForEach(model.quickReactions(for: message), id: \.self) { emoji in
                    Button(emoji) { model.react(emoji, to: message) }
                }
                Button("More Reactions…") { model.showReactionPicker(for: message) }
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

        if model.canForward(message) {
            Button("Forward…", systemImage: "arrowshape.turn.up.right") { model.forward(message) }
        }

        if model.canEdit(message) {
            Button("Edit", systemImage: "pencil") { model.startEditing(message) }
        }
    }

    private var hasManage: Bool {
        model.canSelect(message) || model.canShowInfo(message)
    }

    @ViewBuilder private var manage: some View {
        if model.canSelect(message) {
            Button("Select", systemImage: "checkmark.circle") { model.select(message) }
        }
        if model.canShowInfo(message) {
            Button("Info", systemImage: "info.circle") { model.showInfo(message) }
        }
    }

    private var hasContent: Bool {
        if coordinates != nil { return true }
        switch message.content {
        case .contact: return true
        case .sticker: return message.content.media?.path != nil
        default: return false
        }
    }

    /// What this kind of message offers: a place, a contact, a sticker.
    @ViewBuilder private var content: some View {
        if let place = coordinates {
            Button("Copy Coordinates", systemImage: "mappin.and.ellipse") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(place, forType: .string)
            }
        }

        if case let .contact(displayName, vcard) = message.content {
            Button("Save to Contacts…", systemImage: "person.crop.circle.badge.plus") {
                ContactCardExport.openInContacts(vcard: vcard, name: model.sharedContact(in: message)?.name ?? displayName)
            }
            if let number = model.sharedContact(in: message)?.number {
                Button("Copy Number", systemImage: "phone") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                }
            }
        }

        if case .sticker = message.content, let path = message.content.media?.path {
            Button(model.stickers.isFavorite(path) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: model.stickers.isFavorite(path) ? "star.slash" : "star") {
                model.toggleFavoriteSticker(path)
            }
        }
    }

    /// The attachment: look at it, open it, keep it; or fetch it first.
    @ViewBuilder private var file: some View {
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

    /// Seldom needed: repairing history, and the id for a bug report (as
    /// upstream offers it).
    private var more: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Reload Earlier Messages", systemImage: "arrow.clockwise") {
                model.reloadHistory(before: message)
            }
            .disabled(!model.canReloadHistory(message))

            Button("Copy Message ID", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.id, forType: .string)
            }
        }
    }

    @ViewBuilder private var delete: some View {
        Button("Delete for Me…", systemImage: "trash", role: .destructive) {
            model.confirmDelete(message, forEveryone: false)
        }
        if model.canRevoke(message) {
            Button("Delete for Everyone…", systemImage: "trash", role: .destructive) {
                model.confirmDelete(message, forEveryone: true)
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

    /// "latitude,longitude", as upstream copies a place.
    private var coordinates: String? {
        switch message.content {
        case let .location(latitude, longitude, _, _), let .liveLocation(latitude, longitude, _, _, _, _, _):
            "\(latitude),\(longitude)"
        default: nil
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
