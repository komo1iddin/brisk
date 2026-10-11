/// A document inside a bubble: its icon, its name, and what opens it.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A document: its first page when there is one to show (the sender's
/// preview, or a PDF's cover once here), then the file's own icon as the
/// Finder draws it, its name, and its pages, size and kind.
struct DocumentContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let fileName: String
    let pages: UInt32?
    let model: AppModel

    @State private var preview: NSImage?

    private static let width: CGFloat = 280
    private static let previewHeight: CGFloat = 150

    var body: some View {
        let state = model.conversations.download(MessageKey(chat: message.chat, message: message.id))
        Button(action: activate) {
            VStack(spacing: 0) {
                // The page's room is kept from the start: the timeline
                // measures a row once, before the picture has loaded.
                if hasPreview {
                    Rectangle()
                        .fill(.white)
                        .frame(width: Self.width, height: Self.previewHeight)
                        .overlay(alignment: .top) {
                            if let preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: Self.width)
                                    .transition(.opacity)
                            }
                        }
                        .clipped()
                        .overlay(alignment: .bottom) { Divider() }
                        .accessibilityHidden(true)
                }
                HStack(spacing: Metrics.s) {
                    Image(nsImage: FileIcons.badge(fileName: fileName, mime: media.mime))
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(detail).font(.caption).opacity(0.75)
                    }
                    Spacer(minLength: Metrics.s)
                    if media.path == nil {
                        if state == .downloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.title3)
                                .accessibilityLabel("Download")
                        }
                    }
                }
                .padding(Metrics.s)
            }
            .frame(width: Self.width)
            .background(Palette.inset)
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(.plain)
        .draggableAttachment(message)
        .task(id: Thumbnails.scope([model.accountID, message.chat, message.id, media.path ?? "", Thumbnails.contentID(message.thumbnail)])) { await load() }
    }

    private var detail: String {
        BubbleSource.Document.detail(fileName: fileName, bytes: media.size, pages: pages)
    }

    /// A page to show: the sender's preview, or a PDF that is here.
    private var hasPreview: Bool {
        message.thumbnail != nil
            || (message.mediaURL != nil && DocumentType.of(fileName: fileName, mime: media.mime).conforms(to: .pdf))
    }

    private func load() async {
        model.autoDownload(message)
        // A page is taller than wide and shows at full width, top first.
        let tall = Self.width * 1.5
        if let url = message.mediaURL, DocumentType.of(fileName: fileName, mime: media.mime).conforms(to: .pdf),
           let page = await Thumbnails.document(url, size: CGSize(width: Self.width, height: tall)) {
            // The file itself draws sharper than the sender's small preview.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { preview = page }
        } else if let thumbnail = message.thumbnail {
            let loaded = await Thumbnails.load(thumbnail, key: Thumbnails.scope([model.accountID, message.chat, "document", message.id]), points: tall)
            guard !Task.isCancelled else { return }
            preview = loaded
        } else {
            preview = nil
        }
    }

    private func activate() {
        if let url = message.mediaURL { QuickLook.shared.show([url]) } else { model.download(message) }
    }
}
