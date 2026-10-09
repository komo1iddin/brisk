import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

extension ChatSummary {
    /// Whether the composer shows: a chat closed to us shows why instead.
    var canSend: Bool {
        !locked && !left && !(readOnly && !admin) && !(isChannel && !admin)
    }
}

/// Shown when the chat has nothing, once the archive and phone have said so.
struct EmptyConversation: View {
    var body: some View {
        ContentUnavailableView("No messages here yet", systemImage: "bubble.left.and.bubble.right")
    }
}

/// A spinner while older messages are on their way, if they take a while:
/// the archive usually answers within a frame, and a glass card shown and
/// removed for every page cost more than the page.
struct LoadingOlder: View {
    let loading: Bool
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                ProgressView()
                    .controlSize(.small)
                    .padding(Metrics.s)
                    .modifier(GlassCard())
                    .padding(.top, Metrics.s)
            }
        }
        .task(id: loading) {
            guard loading else {
                shown = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { shown = true }
        }
    }
}

struct ReadOnlyBar: View {
    let chat: ChatSummary

    var body: some View {
        if #available(macOS 26, *) {
            // Floating in glass over the chat, as the composer is.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Metrics.m)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, Metrics.s)
        } else {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Metrics.m)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }

    private var message: LocalizedStringKey {
        if chat.locked { return "Locked chats are read-only in ZapFast." }
        if chat.left { return "You're no longer a participant." }
        if chat.isChannel { return "Only channel admins can post." }
        return "Only admins can send messages."
    }
}

/// Floats over the timeline while older messages are being read and
/// scrolls back to the newest one, with a count of those that arrived.
struct NewestMessageButton: View {
    let newBelow: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .modifier(FloatingSurface(Circle(), interactive: false))
        .overlay(alignment: .topTrailing) {
            if newBelow > 0 {
                Text(newBelow, format: .number)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.tint, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
        .help("Scroll to the newest message")
        .accessibilityLabel(newBelow > 0 ? Text("Newest message, \(newBelow) new") : Text("Newest message"))
    }
}

/// In place of the composer while messages are selected: how many, and
/// what can be done with them. Escape ends selecting.
struct SelectionBar: View {
    let selection: MessageSelection
    let model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: Metrics.m) {
            Button {
                model.cancelSelection()
            } label: {
                Label("Cancel Selection", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .keyboardShortcut(.cancelAction)
            .help("Cancel selection (Esc)")

            Text("\(selection.ids.count) selected")
                .font(.body.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: selection.ids.count)

            Spacer()

            Button {
                model.copySelection { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .help("Copy the selected messages")

            let share = model.shareableSelection
            ShareMenuButton {
                (share.files as [Any]) + (share.text.map { [$0 as Any] } ?? [])
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .disabled(share.isEmpty)
            .help(share.isEmpty ? "Download the selected files to share them" : "Share the selected messages")

            Button {
                confirmingDelete = true
            } label: {
                Label("Delete for Me", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .selectionButton()
            .help("Delete for me")

            Button {
                model.forwardSelection()
            } label: {
                Label("Forward…", systemImage: "arrowshape.turn.up.right")
                    .padding(.horizontal, Metrics.xs)
                    .frame(height: 22)
            }
            .selectionButton(prominent: true)
            .disabled(model.forwardableSelection.isEmpty)
            .help("Forward the selected messages")
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
        .modifier(SelectionBarSurface())
        .confirmationDialog(
            Text("Delete \(selection.ids.count) messages for you?"),
            isPresented: $confirmingDelete
        ) {
            Button("Delete for Me", role: .destructive) { model.deleteSelectionForMe() }
        } message: {
            Text("They are removed from your phone and linked devices. Other people keep their copies. Connect to WhatsApp to delete them. It can't be undone.")
        }
    }
}

private struct SelectionBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

private extension View {
    @ViewBuilder
    func selectionButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).controlSize(.large)
            } else {
                buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}
