/// Small controls the editor's bars are built from: the quality badge and
/// its picker, and one thumbnail.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// "HD" in a rounded box, as WhatsApp draws its quality button.
struct QualityBadge: View {
    let hd: Bool

    var body: some View {
        Text(verbatim: "HD")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .padding(.horizontal, 3)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.5))
            .accessibilityLabel(hd ? "HD quality" : "Standard quality")
    }
}

/// Standard or HD, with what each means and the size it sends.
struct QualityPicker: View {
    @Binding var quality: MediaQuality
    let details: [MediaQuality: String]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Media quality").font(.headline)
            Text("HD quality is clearer. Standard quality uses less storage space and is faster to send.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row(.standard, "Standard quality", "Faster to send, smaller file size")
                Divider().padding(.leading, Metrics.m)
                row(.hd, "HD quality", "Slower to send, can be 6 times larger")
            }
            .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
        }
        .padding(Metrics.l)
        .frame(width: 330)
    }

    private func row(_ option: MediaQuality, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { quality = option }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    HStack(spacing: Metrics.xs) {
                        Text(subtitle)
                        if let detail = details[option] {
                            Text(verbatim: "·")
                            Text(verbatim: detail).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if quality == option {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.s + 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One staged item in the strip: its picture, a ring when shown, and a
/// cross under the pointer.
struct Thumbnail: View {
    let attachment: Attachment
    let state: MediaEditorState
    let selected: Bool
    let showsRemove: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var hovered = false
    private let side: CGFloat = 52

    var body: some View {
        picture
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white, lineWidth: selected ? 2.5 : 0)
            }
            .overlay(alignment: .bottomLeading) {
                if attachment.media == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !attachment.edit.isEmpty {
                    Circle().fill(.yellow).frame(width: 6, height: 6).padding(5)
                        .help("Edited")
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsRemove, hovered {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .transition(.opacity)
                    .help("Remove")
                }
            }
            .scaleEffect(selected ? 1 : 0.9)
            .opacity(selected ? 1 : 0.7)
            .animation(.snappy(duration: 0.18), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    var picture: some View {
        switch attachment.media {
        case .photo:
            if let image = state.photos[attachment.id]?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        case .video:
            if let frame = state.videos[attachment.id]?.frames.first {
                Image(decorative: frame, scale: 1).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        case .none:
            ZStack {
                Color.white.opacity(0.08)
                if let url = attachment.fileURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 34, height: 34)
                }
            }
        }
    }
}
