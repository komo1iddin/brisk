import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A chat's avatar: its profile picture once fetched, else initials for a
/// person or a symbol for a group or channel.
public struct ChatAvatar: View {
    private let chat: ChatSummary
    private let model: AppModel
    private let size: CGFloat
    /// The chat's name when the caller has it: read here, it is read from
    /// stores that change with every message.
    private let title: String?

    public init(chat: ChatSummary, model: AppModel, size: CGFloat, title: String? = nil) {
        self.chat = chat
        self.model = model
        self.size = size
        self.title = title
    }

    public var body: some View {
        AvatarView(
            url: model.avatars.url(for: chat.id),
            seed: chat.id,
            placeholder: placeholder,
            size: size,
            version: model.avatars.version(for: chat.id)
        )
        .overlay(alignment: .bottomTrailing) {
            // Disappearing messages are on, as upstream's timer badge says.
            if (chat.ephemeralExpiration ?? 0) > 0 {
                DisappearingBadge(size: DisappearingBadgeArt.size(forAvatar: size))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
    }

    private var placeholder: AvatarView.Placeholder {
        switch chat.kind {
        case .group: .symbol("person.2.fill")
        case .broadcast: .symbol("megaphone.fill")
        case .direct: .initials(title ?? model.chats.title(for: chat))
        }
    }
}

/// The timer on the avatar of a chat whose messages disappear, drawn as
/// WhatsApp's own reads: a ring that is solid for three quarters and
/// dotted for the last, a hand from the centre, in a quiet grey on a disc
/// of the background, so it sits on the photo's corner rather than shouting
/// in the accent colour.
public enum DisappearingBadgeArt {
    /// The badge's size for an avatar of `avatar` points.
    public static func size(forAvatar avatar: CGFloat) -> CGFloat {
        min(max((avatar * 0.46).rounded(), 13), 22)
    }

    /// WhatsApp's grey for secondary glyphs, in each appearance.
    public static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.53, green: 0.59, blue: 0.63, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.40, blue: 0.44, alpha: 1)
    }

    /// The glyph's strokes in a square of `side` points, y up: the solid
    /// arc, the dots, and the hand.
    public static func glyph(side: CGFloat) -> (ring: CGPath, dots: [CGRect], hand: CGPath, lineWidth: CGFloat) {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let lineWidth = max(1.2, side * 0.09)
        let radius = side * 0.34
        // Clockwise from twelve o'clock round to nine: three quarters.
        let ring = CGMutablePath()
        ring.addArc(center: centre, radius: radius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        // The last quarter, nine to twelve, in three dots.
        let dot = lineWidth
        let dots = [0.25, 0.5, 0.75].map { share -> CGRect in
            let angle = .pi - share * (.pi / 2)
            return CGRect(
                x: centre.x + radius * cos(angle) - dot / 2, y: centre.y + radius * sin(angle) - dot / 2,
                width: dot, height: dot
            )
        }
        // The hand: from the centre up and a little right.
        let hand = CGMutablePath()
        hand.move(to: centre)
        hand.addLine(to: CGPoint(x: centre.x + radius * 0.42, y: centre.y + radius * 0.58))
        return (ring, dots, hand, lineWidth)
    }

    /// Draws the badge into the current AppKit context, in its appearance.
    public static func draw(in rect: CGRect, background: NSColor) {
        background.setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let parts = glyph(side: rect.width)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.setStrokeColor(ink.cgColor)
        context.setFillColor(ink.cgColor)
        context.setLineWidth(parts.lineWidth)
        context.setLineCap(.round)
        context.addPath(parts.ring)
        context.addPath(parts.hand)
        context.strokePath()
        for dot in parts.dots { context.fillEllipse(in: dot) }
        context.restoreGState()
    }
}

/// The timer on the avatar of a chat whose messages disappear.
public struct DisappearingBadge: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvas in
            let side = canvas.width
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: canvas)), with: .style(.background))
            // The art is y up; a canvas is y down.
            let flip = CGAffineTransform(translationX: 0, y: side).scaledBy(x: 1, y: -1)
            let parts = DisappearingBadgeArt.glyph(side: side)
            let ink = GraphicsContext.Shading.color(Color(nsColor: DisappearingBadgeArt.ink))
            let style = StrokeStyle(lineWidth: parts.lineWidth, lineCap: .round)
            context.stroke(Path(parts.ring).applying(flip), with: ink, style: style)
            context.stroke(Path(parts.hand).applying(flip), with: ink, style: style)
            for dot in parts.dots { context.fill(Path(ellipseIn: dot.applying(flip)), with: ink) }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("Disappearing messages"))
    }
}
