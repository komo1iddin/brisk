import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Makes a sticker from a picture (upstream's sticker maker): a square to
/// keep, dragged into place and sized, optionally the see-through
/// background, and emoji to find it by. It is sent, or kept in Favorites.
struct StickerMakerSheet: View {
    let picture: StickerPicture
    let chatID: String
    let model: AppModel

    @State private var image: NSImage?
    @State private var crop: StickerCropInfo
    @State private var keepTransparency = true
    @State private var emoji = ""
    @State private var dragStart: StickerCropInfo?
    @Environment(\.dismiss) private var dismiss

    private let box: CGFloat = 320

    init(picture: StickerPicture, chatID: String, model: AppModel) {
        self.picture = picture
        self.chatID = chatID
        self.model = model
        _crop = State(initialValue: centeredStickerCrop(width: picture.width, height: picture.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Make a Sticker").font(.headline)
            editor
                .frame(width: box, height: box)
                .frame(maxWidth: .infinity)
            LabeledContent("Size") {
                Slider(value: sizeBinding, in: Double(minimumSide)...Double(maximumSide))
            }
            if picture.transparent {
                Toggle("Keep the transparent background", isOn: $keepTransparency)
            }
            TextField("Emoji to find it by (optional)", text: $emoji)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Favorites") { make(sendTo: nil) }
                Button("Send") { make(sendTo: chatID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.session.isConnected)
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
        .task { image = await Thumbnails.load(picture.url, points: box) }
    }

    /// The picture fitted into the box, the kept square outlined, the rest
    /// dimmed; dragging moves the square.
    private var editor: some View {
        let scale = box / CGFloat(max(picture.width, picture.height))
        let shown = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
        let square = CGRect(
            x: CGFloat(crop.x) * scale, y: CGFloat(crop.y) * scale,
            width: CGFloat(crop.side) * scale, height: CGFloat(crop.side) * scale
        )
        return ZStack(alignment: .topLeading) {
            Checkerboard().frame(width: shown.width, height: shown.height)
            if let image {
                Image(nsImage: image).resizable().frame(width: shown.width, height: shown.height)
            }
            Path { path in
                path.addRect(CGRect(origin: .zero, size: shown))
                path.addRect(square)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: square.width, height: square.height)
                .offset(x: square.minX, y: square.minY)
        }
        .frame(width: shown.width, height: shown.height)
        .contentShape(.rect)
        .gesture(DragGesture().onChanged { value in
            let start = dragStart ?? crop
            dragStart = start
            move(from: start, by: CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
        }.onEnded { _ in dragStart = nil })
        .accessibilityLabel("The part of the picture the sticker keeps")
    }

    private var maximumSide: UInt32 { max(1, min(picture.width, picture.height)) }
    private var minimumSide: UInt32 { max(1, maximumSide / 4) }

    /// Resizing keeps the square's centre where it can.
    private var sizeBinding: Binding<Double> {
        Binding(
            get: { Double(crop.side) },
            set: { value in
                let side = UInt32(value.rounded())
                let centerX = Int(crop.x) + Int(crop.side) / 2
                let centerY = Int(crop.y) + Int(crop.side) / 2
                crop = clamped(x: centerX - Int(side) / 2, y: centerY - Int(side) / 2, side: side)
            }
        )
    }

    private func move(from start: StickerCropInfo, by delta: CGSize) {
        crop = clamped(x: Int(start.x) + Int(delta.width), y: Int(start.y) + Int(delta.height), side: start.side)
    }

    private func clamped(x: Int, y: Int, side: UInt32) -> StickerCropInfo {
        let side = min(max(side, minimumSide), maximumSide)
        let x = min(max(0, x), Int(picture.width) - Int(side))
        let y = min(max(0, y), Int(picture.height) - Int(side))
        return StickerCropInfo(x: UInt32(max(0, x)), y: UInt32(max(0, y)), side: side)
    }

    private func make(sendTo chat: String?) {
        let emojis = emoji.filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }.map(String.init)
        model.makeSticker(from: picture, crop: crop, keepTransparency: keepTransparency, emojis: emojis, sendTo: chat)
        dismiss()
    }
}

/// The usual grey checks behind see-through pixels.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(.gray.opacity(0.25))
                    )
                }
            }
        }
    }
}
