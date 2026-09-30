#if DEBUG
import SwiftUI
import ZapFastBridge
import ZapFastCore

/// The media editor over a made-up photo in each of its tools, for checking
/// its layout without a linked account (see the shell's debug snapshot).
public enum MediaEditorGallery {
    public static let modes = ["browse", "crop", "draw", "text"]

    public static func view(mode: String, model: AppModel) -> some View {
        let chat = "gallery@s.whatsapp.net"
        if model.attachments[chat] == nil, let image = picture(), let pasted = PastedImage(image) {
            model.stage(image: pasted, in: chat)
            model.stage(image: pasted, in: chat)
            if let first = model.attachments[chat]?.first {
                var edit = MediaEdit()
                edit.strokes = [MediaStroke(
                    brush: .marker, color: MediaColor(red: 1, green: 0.8, blue: 0),
                    points: (0..<24).map { CGPoint(x: 0.15 + Double($0) * 0.02, y: 0.7 + sin(Double($0) / 3) * 0.05) }
                )]
                edit.overlays = [
                    MediaOverlay(content: .text("Trusted"), color: .white, style: .label, center: CGPoint(x: 0.3, y: 0.25), size: 0.05),
                    MediaOverlay(content: .emoji("🎉"), center: CGPoint(x: 0.8, y: 0.3), size: 0.08, rotation: 0.3),
                ]
                edit.crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.85)
                model.setEdit(edit, for: first.id, in: chat)
                model.setCaption("A selection of our customers", for: first.id, in: chat)
            }
        }
        let state = MediaEditorState()
        if let staged = model.attachments[chat], let image = picture() {
            for attachment in staged {
                state.preload(EditorPhoto(image: image, pixelated: MediaExport.pixelate(image), original: CGSize(width: 2400, height: 1600)), for: attachment.id)
            }
            state.selectedID = staged.first?.id
            state.selectedOverlay = mode == "browse" ? staged.first?.edit.overlays.first?.id : nil
        }
        switch mode {
        case "crop":
            state.mode = .crop
            state.editBeforeCrop = MediaEdit()
        case "draw":
            state.mode = .draw
        case "text":
            state.mode = .text
            state.draftText = MediaOverlay(content: .text("Hello"), color: MediaColor(red: 0.2, green: 0.8, blue: 0.4), style: .subtle)
        default:
            break
        }
        return MediaEditorView(chatID: chat, model: model, state: state)
            // The editor's window is always dark.
            .environment(\.colorScheme, .dark)
    }

    /// A gradient with shapes, 1200 × 800.
    private static func picture() -> CGImage? {
        let width = 1200, height = 800
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [CGColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1), CGColor(srgbRed: 0.95, green: 0.55, blue: 0.3, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 150, y: 200, width: 300, height: 300))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 650, y: 150, width: 380, height: 220))
        return context.makeImage()
    }
}
#endif
