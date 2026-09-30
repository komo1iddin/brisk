import AppKit
import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Words or an emoji as they sit on the picture. The same view draws them
/// on screen and, through `ImageRenderer`, into the file that is sent.
struct OverlayLabel: View {
    let overlay: MediaOverlay
    /// The font size in points: the overlay's share of the canvas's longer
    /// side, at the size the canvas is drawn.
    let fontSize: CGFloat

    var body: some View {
        Group {
            switch overlay.content {
            case .emoji(let emoji):
                Text(verbatim: emoji)
                    .font(.system(size: fontSize))
            case .text(let text):
                styled(Text(verbatim: text))
            }
        }
        .fixedSize()
        // Room for the shadow, which a renderer would otherwise cut off.
        .padding(fontSize * 0.12)
    }

    @ViewBuilder
    private func styled(_ text: Text) -> some View {
        let color = Color(overlay.color)
        let base = text
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .multilineTextAlignment(overlay.alignment.textAlignment)
        switch overlay.style {
        case .plain:
            base
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.35), radius: fontSize * 0.06, y: fontSize * 0.02)
        case .label:
            base
                .foregroundStyle(overlay.color.isLight ? Color.black : Color.white)
                .padding(.horizontal, fontSize * 0.32)
                .padding(.vertical, fontSize * 0.12)
                .background(color, in: .rect(cornerRadius: fontSize * 0.28, style: .continuous))
        case .subtle:
            base
                .foregroundStyle(color)
                .padding(.horizontal, fontSize * 0.32)
                .padding(.vertical, fontSize * 0.12)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: fontSize * 0.28, style: .continuous))
        }
    }

    /// The export's drawing of an overlay, for a canvas whose longer side
    /// is `longSide` pixels.
    @MainActor
    static func render(_ overlay: MediaOverlay, longSide: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: OverlayLabel(overlay: overlay, fontSize: CGFloat(overlay.size) * longSide))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

extension Color {
    init(_ color: MediaColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension MediaOverlay.Alignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    var next: Self {
        Self(rawValue: (rawValue + 1) % Self.allCases.count) ?? .center
    }
}

extension MediaOverlay.TextStyle {
    var next: Self {
        Self(rawValue: (rawValue + 1) % Self.allCases.count) ?? .plain
    }
}

extension MediaStroke.Brush {
    var title: LocalizedStringKey {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil"
        case .marker: "paintbrush.pointed"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        }
    }
}

// MARK: Buttons

/// The editor's round buttons on its dark backdrop: a soft disc that
/// brightens under the pointer, and a white one while its tool is on.
struct EditorButtonStyle: ButtonStyle {
    var active = false
    var prominent = false
    var diameter: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        EditorButtonBody(configuration: configuration, active: active, prominent: prominent, diameter: diameter)
    }
}

private struct EditorButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let prominent: Bool
    let diameter: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: diameter * 0.42, weight: .medium))
            .foregroundStyle(active ? Color.black : .white)
            .frame(width: diameter, height: diameter)
            .background(fill, in: .circle)
            .contentShape(.circle)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.2), value: active)
            .onHover { hovered = $0 }
    }

    private var fill: AnyShapeStyle {
        // The chat's own colour, as its Send button has.
        if prominent { return AnyShapeStyle(.tint) }
        if active { return AnyShapeStyle(Color.white) }
        return AnyShapeStyle(Color.white.opacity(hovered ? 0.2 : 0.12))
    }
}

extension View {
    func editorButton(active: Bool = false, prominent: Bool = false, diameter: CGFloat = 36) -> some View {
        buttonStyle(EditorButtonStyle(active: active, prominent: prominent, diameter: diameter))
    }
}

// MARK: Colour strip

/// A vertical strip of colours, as on the phone: white to black, then the
/// hues. Dragging along it picks; the knob shows the colour.
struct ColorStrip: View {
    @Binding var color: MediaColor
    @State private var position: Double = 0
    @State private var dragging = false

    private let height: CGFloat = 220
    private let width: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(LinearGradient(stops: Self.stops, startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: width, height: height)
            Circle()
                .fill(Color(color))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: dragging ? 30 : 22, height: dragging ? 30 : 22)
                .offset(x: dragging ? -26 : 0, y: CGFloat(position) * height - (dragging ? 15 : 11))
                .animation(.snappy(duration: 0.18), value: dragging)
                .allowsHitTesting(false)
        }
        .frame(width: 44, height: height)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    position = min(max(value.location.y / height, 0), 1)
                    color = MediaColor.strip(position)
                }
                .onEnded { _ in dragging = false }
        )
        .onAppear { position = Self.position(of: color) }
        .help("Colour")
        .accessibilityElement()
        .accessibilityLabel("Colour")
        .accessibilityAdjustableAction { direction in
            position = min(max(position + (direction == .increment ? 0.05 : -0.05), 0), 1)
            color = MediaColor.strip(position)
        }
    }

    private static let stops: [Gradient.Stop] = stride(from: 0.0, through: 1.0, by: 0.02).map {
        Gradient.Stop(color: Color(MediaColor.strip($0)), location: $0)
    }

    /// Where a colour sits on the strip, as near as it can be found.
    private static func position(of color: MediaColor) -> Double {
        var best = 0.0, distance = Double.infinity
        for step in stride(from: 0.0, through: 1.0, by: 0.005) {
            let candidate = MediaColor.strip(step)
            let difference = pow(candidate.red - color.red, 2) + pow(candidate.green - color.green, 2) + pow(candidate.blue - color.blue, 2)
            if difference < distance { distance = difference; best = step }
        }
        return best
    }
}

// MARK: Keys

/// Keys the editor takes for itself while no text field has them: Escape,
/// Delete, and the arrows. `handle` returns whether it used the key.
struct EditorKeys: NSViewRepresentable {
    let handle: (_ key: Key, _ inTextField: Bool) -> Bool

    enum Key {
        case escape, delete, left, right, commandZ, commandShiftZ
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    final class Coordinator {
        var handle: (Key, Bool) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(handle: @escaping (Key, Bool) -> Bool) {
            self.handle = handle
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      window.attachedSheet == nil, let key = Self.key(of: event)
                else { return event }
                let inTextField = window.firstResponder is NSText
                return self.handle(key, inTextField) ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func key(of event: NSEvent) -> Key? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
            switch event.keyCode {
            case 53 where flags.isEmpty: return .escape
            case 51 where flags.isEmpty, 117 where flags.isEmpty: return .delete
            case 123 where flags.isEmpty: return .left
            case 124 where flags.isEmpty: return .right
            case 6 where flags == .command: return .commandZ
            case 6 where flags == [.command, .shift]: return .commandShiftZ
            default: return nil
            }
        }
    }
}
