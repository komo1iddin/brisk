/// The cards a message can carry instead of plain text: a shared contact
/// and a link preview.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A shared contact, as on the phone: the person and their number, then
/// Message and Add when the number is a WhatsApp account (upstream's
/// contact bubble). A card without a number still shows its name.
struct ContactCard: View {
    let message: MessageRecord
    let displayName: String
    let vcard: String
    let model: AppModel

    var body: some View {
        let contact = model.sharedContact(in: message)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.s) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact?.name ?? displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if let number = contact?.number {
                        Text(number).font(.callout).opacity(0.75).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Metrics.s)

            if let contact, let account = contact.account {
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    action("Message") { model.chat(with: contact) }
                    if !model.isKnownContact(account) {
                        Divider().frame(height: 20).opacity(0.6)
                        action("Add") { model.addContact(contact) }
                            .disabled(!model.session.isConnected)
                    }
                }
            }
        }
        .frame(minWidth: 240)
        .background(Palette.inset, in: .rect(cornerRadius: Metrics.controlRadius))
        .accessibilityElement(children: .contain)
    }

    private func action(_ title: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

// MARK: - Link preview

struct LinkPreviewCard: View {
    let preview: LinkPreviewInfo
    let thumbnail: Data?
    let key: String
    let model: AppModel

    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.s) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = preview.title {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(2)
                }
                if let description = preview.description {
                    Text(description).font(.caption).lineLimit(2).opacity(0.8)
                }
                Text(URL(string: preview.url)?.host() ?? preview.url)
                    .font(.caption2).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.s)
        .background(Palette.inset, in: .rect(cornerRadius: Metrics.controlRadius))
        .task(id: key) {
            guard let thumbnail else { return }
            image = await Thumbnails.load(thumbnail, key: "preview-\(key)", points: 56)
        }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { open() }
    }

    private func open() {
        guard let url = URL(string: preview.url), !model.openInviteLink(url) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Media
