import SwiftUI

/// The unread count pill, or an empty dot for "marked unread".
public struct UnreadBadge: View {
    private let count: UInt32
    private let muted: Bool

    public init(count: UInt32, muted: Bool) {
        self.count = count
        self.muted = muted
    }

    public var body: some View {
        Group {
            if count > 0 {
                Text(count > 999 ? "999+" : "\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(tint))
                    .foregroundStyle(.white)
            } else {
                Circle().fill(tint).frame(width: 10, height: 10)
            }
        }
        .accessibilityLabel(count > 0 ? Text("\(count) unread") : Text("Unread"))
    }

    private var tint: Color {
        muted ? Color.secondary.opacity(0.6) : Color.accentColor
    }
}

/// Outgoing delivery state as the phone draws it: clock, one tick, two
/// ticks, two tinted ticks.
public struct DeliveryTicks: View {
    public enum State: Sendable {
        case pending, sent, delivered, read, failed
    }

    private let state: State
    private let readTint: Color

    public init(_ state: State, readTint: Color = .accentColor) {
        self.state = state
        self.readTint = readTint
    }

    public var body: some View {
        Group {
            switch state {
            case .pending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .delivered, .read:
                ZStack(alignment: .leading) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark").offset(x: 4)
                }
                .padding(.trailing, 4)
                .foregroundStyle(state == .read ? readTint : Color.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 9, weight: .bold))
        .accessibilityLabel(label)
    }

    private var label: Text {
        switch state {
        case .pending: Text("Sending")
        case .sent: Text("Sent")
        case .delivered: Text("Delivered")
        case .read: Text("Read")
        case .failed: Text("Not sent")
        }
    }
}

/// Transient information or an error, dismissible, at the top of a pane.
public struct NoticeBanner: View {
    private let text: String
    private let isError: Bool
    private let dismiss: () -> Void

    public init(text: String, isError: Bool, dismiss: @escaping () -> Void) {
        self.text = text
        self.isError = isError
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: Metrics.s) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.accentColor)
            Text(text)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
        .modifier(GlassCard())
    }
}

/// Liquid Glass on macOS 26, a material card before it.
public struct GlassCard: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        } else {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: Metrics.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .strokeBorder(.separator, lineWidth: Metrics.hairline)
                )
        }
    }
}

/// A small control floating over the timeline (the "newest message" button,
/// a message's Reply and React discs): Liquid Glass on macOS 26, a lifted
/// material before it.
public struct FloatingSurface<S: InsettableShape>: ViewModifier {
    private let shape: S
    private let interactive: Bool

    /// `interactive` glass swells under the pointer; a control beside the
    /// window's edge is better still.
    public init(_ shape: S, interactive: Bool = true) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: Metrics.hairline))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
}

/// Glass shapes side by side (the composer's field and buttons, a message's
/// hover discs) drawn as one group on macOS 26, so they blend and morph
/// together instead of each sampling the others.
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
