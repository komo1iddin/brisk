import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// One message in the timeline: the bubble on its side, reactions under it,
/// and the message's context menu.
struct MessageRow: View {
    let message: MessageRecord
    let startsRun: Bool
    /// The last message of its sender's run: in a group, their photo
    /// beside it, and the bubble's tail.
    var endsRun = true
    let isGroup: Bool
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let selecting = model.selection?.chat == message.chat
        HStack(alignment: .bottom, spacing: 0) {
            if message.fromMe { Spacer(minLength: 72) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: -Metrics.xs) {
                MessageBubble(
                    message: message,
                    senderName: senderName,
                    endsRun: endsRun,
                    model: model
                )
                .contextMenu { MessageActions(message: message, model: model) }
                .overlay(alignment: .bottomLeading) {
                    if avatarRoom, endsRun {
                        // In the photos' column, level with the bubble's bottom.
                        Button { model.showInfo(in: message.chat, person: message.sender) } label: {
                            AvatarView(
                                url: model.avatars.url(for: message.sender), seed: message.sender,
                                placeholder: .initials(model.chats.personName(message.sender, hint: message.senderName)),
                                size: TimelineGeometry.avatarSize, version: model.avatars.version(for: message.sender)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .offset(x: -(TimelineGeometry.avatarSize + TimelineGeometry.avatarGap))
                    }
                }
                .popover(isPresented: pickingReaction, arrowEdge: .top) {
                    ReactionPicker(
                        quick: model.quickReactions(for: message),
                        mine: message.reactions.first(where: \.fromMe)?.emoji,
                        frequent: model.preferences.reactionEmoji.map(\.emoji)
                    ) { model.react($0, to: message) }
                }
                .overlay(alignment: message.fromMe ? .leading : .trailing) {
                    if isLive, !selecting, hovering || pickingReaction.wrappedValue {
                        // Beside the bubble, clear of it, on the side away
                        // from the window's edge.
                        HoverActions(message: message, model: model)
                            .fixedSize()
                            .offset(x: message.fromMe ? -HoverActions.reach : HoverActions.reach)
                            .transition(.opacity)
                    }
                }

                if !message.reactions.isEmpty {
                    ReactionPills(reactions: message.reactions, fromMe: message.fromMe)
                        .padding(.horizontal, Metrics.s)
                }
            }
            .frame(maxWidth: Metrics.bubbleMaxWidth, alignment: message.fromMe ? .trailing : .leading)
            .padding(.leading, avatarRoom ? TimelineGeometry.avatarRoom : 0)
            // Room for the checkbox, without changing the row's height.
            .offset(x: selecting && !message.fromMe ? Self.checkboxRoom : 0)
            if !message.fromMe { Spacer(minLength: 72) }
        }
        .padding(.horizontal, Metrics.l)
        .overlay(alignment: .leading) {
            if selecting {
                SelectionCheckbox(selected: model.isSelected(message), enabled: model.canSelect(message))
                    .padding(.leading, Metrics.m)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.top, startsRun ? Metrics.s : Metrics.xxs)
        .padding(.bottom, Metrics.xxs)
        .contentShape(.rect)
        .overlay {
            // While selecting, a click anywhere on the row picks it, and
            // nothing inside (links, text) takes the click.
            if selecting {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.shift) {
                            model.selectRange(to: message)
                        } else {
                            model.toggleSelected(message)
                        }
                    }
            }
        }
        // ⌘-click starts selecting, as upstream's Command-click does.
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { model.select(message) })
        .animation(.zf(reduceMotion, duration: 0.2), value: selecting)
        .onHover { hovering = $0 }
        .animation(.zf(reduceMotion, duration: 0.12), value: hovering)
        // A reused cell shows another message.
        .onChange(of: message.id) {
            hovering = false
        }
        // What the pointer finds beside the bubble, and a click does while
        // selecting, as actions for VoiceOver.
        .accessibilityActions {
            if selecting {
                if model.canSelect(message) {
                    Button(model.isSelected(message) ? "Deselect" : "Select") { model.toggleSelected(message) }
                }
            } else if isLive {
                Button("Reply") { model.reply(to: message) }
                Button("React") { model.showReactionPicker(for: message) }
                if model.canSelect(message) {
                    Button("Select") { model.select(message) }
                }
            }
        }
        .background {
            // A search hit or quote just jumped to, marked for a moment.
            if isHighlighted {
                Rectangle().fill(.tint.opacity(0.18)).transition(.opacity)
            } else if model.isSelected(message) {
                Rectangle().fill(.tint.opacity(0.12))
            }
        }
        .animation(.zf(reduceMotion, duration: 0.6), value: isHighlighted)
    }

    private static let checkboxRoom: CGFloat = 28

    /// An incoming message in a group starts after the senders' photos.
    private var avatarRoom: Bool {
        isGroup && !message.fromMe
    }

    /// The reaction picker hangs from the bubble, from the hover control
    /// or the context menu alike.
    private var pickingReaction: Binding<Bool> {
        Binding(
            get: { model.reactionTarget == MessageKey(chat: message.chat, message: message.id) },
            set: { if !$0, model.reactionTarget == MessageKey(chat: message.chat, message: message.id) { model.reactionTarget = nil } }
        )
    }

    private var isLive: Bool {
        if case .revoked = message.content { false } else { true }
    }

    private var isHighlighted: Bool {
        model.highlighted == MessageKey(chat: message.chat, message: message.id)
    }

    /// Shown on the first message of a run in a group.
    private var senderName: String? {
        guard startsRun, !message.fromMe, isGroup else { return nil }
        return model.chats.personName(message.sender, hint: message.senderName)
    }
}

/// Reactions grouped by emoji, with a count when more than one person chose
/// it. Ours is not marked, as on the phone: the reaction picker shows it.
private struct ReactionPills: View {
    let reactions: [ReactionInfo]
    let fromMe: Bool

    var body: some View {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        HStack(spacing: Metrics.xxs) {
            ForEach(groups, id: \.emoji) { group in
                HStack(spacing: 2) {
                    Text(group.emoji)
                    if group.count > 1 {
                        Text("\(group.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reply and React beside the message under the pointer, as upstream's
/// hover controls and WhatsApp's: separate discs, opaque so the wallpaper
/// does not show through, lifted like a bubble. Everything else stays in
/// the context menu.
struct HoverActions: View {
    let message: MessageRecord
    let model: AppModel

    static let size: CGFloat = 34
    static let spacing: CGFloat = 6
    static let gap: CGFloat = 8
    /// How far the pair sits from the bubble's edge it is pinned to: its
    /// own width and the gap.
    static let reach = size * 2 + spacing + gap
    /// Both discs side by side.
    static let pairSize = CGSize(width: size * 2 + spacing, height: size)

    var body: some View {
        // Reply nearest the bubble, React beyond it, on either side.
        GlassGroup(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                if message.fromMe {
                    react
                    reply
                } else {
                    reply
                    react
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var reply: some View {
        HoverDisc(title: "Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: message) }
    }

    private var react: some View {
        HoverDisc(title: "React", systemImage: "face.smiling") { model.showReactionPicker(for: message) }
    }
}

private struct HoverDisc: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: HoverActions.size, height: HoverActions.size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .modifier(HoverDiscSurface(hovered: hovered))
        .onHover { hovered = $0 }
        .help(title)
    }
}

/// Liquid Glass on macOS 26, as WhatsApp's are; before it, an opaque disc
/// lifted like a bubble so the wallpaper does not show through.
private struct HoverDiscSurface: ViewModifier {
    let hovered: Bool
    @Environment(\.chatTheme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.modifier(FloatingSurface(Circle()))
        } else {
            content.background {
                Circle()
                    .fill(theme.chip)
                    .overlay(Circle().fill(.primary.opacity(hovered ? 0.06 : 0)))
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            }
        }
    }
}

/// A row's round checkbox while messages are being selected.
private struct SelectionCheckbox: View {
    let selected: Bool
    let enabled: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .symbolRenderingMode(selected ? .monochrome : .hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .opacity(enabled ? 1 : 0.3)
            .accessibilityLabel("Selected")
            .accessibilityValue(selected ? Text("On") : Text("Off"))
            .accessibilityAddTraits(.isToggle)
    }
}
