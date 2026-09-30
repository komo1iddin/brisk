import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A sticker pack someone shared: its stickers (animated ones move under
/// the pointer), a click sends one to the chat, and Add keeps the pack.
struct StickerPackSheet: View {
    let preview: StickerPackPreview
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            switch preview.state {
            case .loading:
                Text("Sticker Pack").font(.headline)
                HStack(spacing: Metrics.s) {
                    ProgressView().controlSize(.small)
                    Text("Downloading the stickers…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                footer(canAdd: false)
            case let .ready(pack, publisher):
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pack.name).font(.headline)
                    if !publisher.isEmpty {
                        Text(verbatim: publisher).font(.callout).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: Metrics.s)], spacing: Metrics.s) {
                        ForEach(pack.stickers, id: \.self) { path in
                            PackSticker(path: path) {
                                model.sendSticker(path, in: preview.chat)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 360)
                Text("Click a sticker to send it.").font(.caption).foregroundStyle(.secondary)
                footer(canAdd: true)
            case .failed(let error):
                Text("Sticker Pack").font(.headline)
                Text(error).fixedSize(horizontal: false, vertical: true)
                footer(canAdd: false)
            }
        }
        .padding(Metrics.l)
        .frame(width: 420)
    }

    private func footer(canAdd: Bool) -> some View {
        HStack {
            Spacer()
            Button("Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if canAdd {
                Button("Add to My Stickers") { model.addViewedStickerPack() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct PackSticker: View {
    let path: String
    let send: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: send) {
            AnimatedImage(url: URL(filePath: path), still: image, points: 80, playing: hovering && !reduceMotion)
                .frame(width: 80, height: 80)
                .padding(Metrics.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius)
                        .fill(.fill.tertiary)
                        .opacity(hovering ? 0.6 : 0)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: path) { image = await Thumbnails.load(URL(filePath: path), points: 80) }
        .accessibilityLabel("Sticker")
    }
}
