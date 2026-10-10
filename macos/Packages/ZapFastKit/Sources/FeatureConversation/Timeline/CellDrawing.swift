/// Drawing a timeline cell: running AppKit drawing into a layer, and the
/// glyphs the cells paint.

import AppKit
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Runs AppKit drawing into a layer's context, top-left based, with the
/// view's appearance so dynamic colours resolve for light or dark.
@MainActor
func withAppKitContext(_ context: CGContext, appearance: NSAppearance?, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance(draw)
    NSGraphicsContext.restoreGraphicsState()
}

/// SF Symbols drawn as tinted images, cached per name, size and colour.
@MainActor
enum Symbols {
    private static var cache: [String: NSImage] = [:]

    static func draw(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, offset: CGFloat = 0) {
        guard let (image, alpha) = image(name, pointSize: pointSize, weight: weight, color: color) else { return }
        let size = image.size
        let origin = CGPoint(x: rect.minX + offset, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// The symbol in the colour, opaque, and the alpha to draw it at.
    /// Monochrome, as SwiftUI draws a symbol in text: palette colours fill
    /// some symbols' inner layers (the iPhone's screen).
    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> (NSImage, CGFloat)? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let alpha = resolved.alphaComponent
        let opaque = resolved.withAlphaComponent(1)
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(opaque.description)"
        if let cached = cache[key] { return (cached, alpha) }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let made = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            opaque.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[key] = made
        return (made, alpha)
    }

    /// Centred in `rect`: one colour tints it (as `image` does), more
    /// colours paint its layers in order.
    static func drawCentered(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, palette: [NSColor]) {
        let image: NSImage
        var alpha: CGFloat = 1
        if palette.count == 1 {
            guard let (tinted, fraction) = Self.image(name, pointSize: pointSize, weight: weight, color: palette[0]) else { return }
            image = tinted
            alpha = fraction
        } else {
            let colors = palette.map { $0.usingColorSpace(.sRGB) ?? $0 }
            let key = "palette|\(name)|\(pointSize)|\(weight.rawValue)|\(colors.map(\.description).joined(separator: ","))"
            if let cached = cache[key] {
                image = cached
            } else {
                let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                    .applying(.init(paletteColors: colors))
                guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else { return }
                cache[key] = made
                image = made
            }
        }
        let size = image.size
        let origin = CGPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded())
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// `DeliveryTicks`, drawn: one tick sent, two delivered, two tinted read.
    static func drawTicks(_ state: DeliveryTicks.State, in rect: CGRect, secondary: NSColor, read: NSColor) {
        switch state {
        case .pending:
            draw("clock", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .sent:
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .delivered, .read:
            let color = state == .read ? read : secondary
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color)
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color, offset: 4)
        case .failed:
            draw("exclamationmark.circle.fill", in: rect, pointSize: 9, weight: .bold, color: .systemRed)
        }
    }
}
