import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Reply preview, attach button, message field, and send button.
struct ComposerBar: View {
    let chatID: String
    @Bindable var model: AppModel

    @State private var fieldHeight: CGFloat = 22
    @State private var choosingFiles = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Metrics.s) {
            if let reply = model.replyingTo[chatID] {
                ReplyPreview(message: reply, model: model) {
                    withAnimation(.zf(reduceMotion)) { model.cancelReply(in: chatID) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: Metrics.s) {
                Button {
                    choosingFiles = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Attach files")
                .accessibilityLabel("Attach files")

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: textBinding,
                        height: $fieldHeight,
                        focusToken: chatID,
                        maxHeight: 180,
                        onSubmit: { model.sendText(in: chatID) },
                        onEdit: { model.composerEdited(in: chatID) },
                        onPasteFiles: { model.sendFiles($0, in: chatID) }
                    )
                    .frame(height: fieldHeight)
                }
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, Metrics.xs + 1)
                .background(.background, in: .rect(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.separator))

                Button {
                    model.sendText(in: chatID)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.sendFiles(urls, in: chatID) }
        }
    }

    private var text: String {
        model.composerText[chatID] ?? ""
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.composerText[chatID] ?? "" },
            set: { model.composerText[chatID] = $0 }
        )
    }
}

private struct ReplyPreview: View {
    let message: MessageRecord
    let model: AppModel
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Metrics.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.sender(message.sender))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(model.chats.displayName(message.sender, hint: message.senderName))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.sender(message.sender))
                Text(message.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel reply")
        }
        .frame(height: 36)
        .padding(.horizontal, Metrics.xs)
    }
}
