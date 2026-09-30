import QuickLookThumbnailing
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Attachments waiting above the field, each with the system's thumbnail
/// and a button to take it out; clicking one previews it in Quick Look.
/// The field's text goes with the first as its caption.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let remove: (Attachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.s) {
                ForEach(attachments) { attachment in
                    AttachmentTile(attachment: attachment) { remove(attachment.id) }
                }
            }
            .padding(.vertical, Metrics.xs)
            .padding(.horizontal, Metrics.xxs)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }
}

private struct AttachmentTile: View {
    let attachment: Attachment
    let remove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false
    private let side: CGFloat = 72

    var body: some View {
        VStack(spacing: Metrics.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(.fill.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "doc").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(Metrics.xxs)
                .opacity(hovering ? 1 : 0.85)
                .help("Remove")
                .accessibilityLabel("Remove \(name)")
            }
            .onTapGesture(perform: preview)

            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
        }
        .onHover { hovering = $0 }
        .task(id: attachment.id) { thumbnail = await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAction(named: "Preview", preview)
        .accessibilityAction(named: "Remove", remove)
    }

    private var name: String {
        switch attachment.kind {
        case .file(let url): url.lastPathComponent
        case .image: String(localized: "Pasted image")
        }
    }

    private func load() async -> NSImage? {
        switch attachment.kind {
        case .image(let image):
            return image.cgImage.map { NSImage(cgImage: $0, size: .zero) }
        case .file(let url):
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .all
            )
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation?.nsImage
        }
    }

    private func preview() {
        switch attachment.kind {
        case .file(let url):
            QuickLook.shared.show([url])
        case .image:
            break
        }
    }
}
