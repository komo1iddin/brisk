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
    @State private var pickingSticker = false
    @State private var mentions = MentionTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let suggesting = !mentions.suggestions.isEmpty
        VStack(spacing: Metrics.s) {
            if suggesting {
                MentionSuggestions(tracker: mentions, model: model)
                    .transition(.opacity)
            }
            if let message = model.editing[chatID] {
                EditPreview(message: message, escapes: !suggesting) {
                    withAnimation(.zf(reduceMotion)) { model.cancelEditing(in: chatID) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let reply = model.replyingTo[chatID] {
                ReplyPreview(message: reply, model: model, escapes: !suggesting) {
                    withAnimation(.zf(reduceMotion)) { model.cancelReply(in: chatID) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if model.recorder.isRecording {
                RecordingBar(recorder: model.recorder) {
                    model.cancelRecording()
                } send: {
                    model.sendRecording(in: chatID)
                }
            } else {
                editor
            }
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: pollSheet) {
            CreatePollSheet(chatID: chatID, model: model)
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.sendFiles(urls, in: chatID) }
        }
        .onAppear(perform: bindMentions)
        .onChange(of: chatID) {
            mentions.cancel()
            bindMentions()
        }
    }

    private func bindMentions() {
        let chat = chatID, model = model
        mentions.candidates = { model.mentionCandidates(in: chat, query: $0) }
        mentions.onPick = { model.addMention($0, in: chat) }
    }

    private var editor: some View {
            HStack(alignment: .bottom, spacing: Metrics.s) {
                Menu {
                    Button("Send Files…", systemImage: "paperclip") { choosingFiles = true }
                    Button("Create Poll…", systemImage: "chart.bar.doc.horizontal") {
                        model.pollComposerChat = chatID
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files or create a poll")
                .accessibilityLabel("Attach")

                Button {
                    pickingSticker.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Stickers and GIFs")
                .accessibilityLabel("Stickers and GIFs")
                .disabled(isEditing)
                .popover(isPresented: $pickingSticker, arrowEdge: .top) {
                    StickerPicker(chatID: chatID, model: model) { pickingSticker = false }
                }

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
                        focusToken: "\(chatID)#\(model.composerFocusRequests)",
                        maxHeight: 180,
                        onSubmit: { model.sendText(in: chatID) },
                        onEdit: { model.composerEdited(in: chatID) },
                        onPasteFiles: { model.sendFiles($0, in: chatID) },
                        onUpInEmpty: { model.editLastMessage(in: chatID) },
                        mentions: mentions,
                        mentionNames: (model.composerMentions[chatID] ?? []).map(\.name)
                    )
                    .frame(height: fieldHeight)
                }
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, Metrics.xs + 1)
                .background(.background, in: .rect(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.separator))

                if isEditing {
                    Button {
                        model.sendText(in: chatID)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBlank)
                    .help("Save changes")
                    .accessibilityLabel("Save changes")
                } else if isBlank {
                    Button {
                        model.startRecording()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Record a voice message")
                    .accessibilityLabel("Record a voice message")
                } else {
                    Button {
                        model.sendText(in: chatID)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
    }

    private var text: String {
        model.composerText[chatID] ?? ""
    }

    private var pollSheet: Binding<Bool> {
        Binding(
            get: { model.pollComposerChat == chatID },
            set: { if !$0 { model.pollComposerChat = nil } }
        )
    }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditing: Bool {
        model.editing[chatID] != nil
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.composerText[chatID] ?? "" },
            set: { model.composerText[chatID] = $0 }
        )
    }
}

/// While recording: discard, a red dot with the elapsed time, the live
/// input level, and send.
private struct RecordingBar: View {
    let recorder: VoiceRecorder
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        HStack(spacing: Metrics.m) {
            Button(action: cancel) {
                Image(systemName: "trash")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .keyboardShortcut(.cancelAction)
            .help("Discard recording")
            .accessibilityLabel("Discard recording")

            Circle().fill(.red).frame(width: 10, height: 10)
                .symbolEffectPulseIfAvailable()

            if case .recording(let since) = recorder.state {
                TimelineView(.periodic(from: since, by: 0.5)) { context in
                    Text(Duration.seconds(Int(context.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                        .font(.body.monospacedDigit())
                }
            }

            LevelMeter(levels: recorder.levels)
                .frame(height: 24)
                .frame(maxWidth: .infinity)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
            .help("Send voice message")
            .accessibilityLabel("Send voice message")
        }
        .frame(minHeight: 34)
    }
}

private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = 48
            let step = size.width / CGFloat(count)
            let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
            for (index, level) in padded.enumerated() {
                let height = max(2, size.height * CGFloat(level))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1.5, step * 0.5), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// A gentle pulse, off when Reduce Motion is on.
    func symbolEffectPulseIfAvailable() -> some View {
        modifier(Pulse())
    }
}

private struct Pulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Above the field while a message is being edited: its old text, and a
/// button (or Escape) to leave it as it was.
private struct EditPreview: View {
    let message: MessageRecord
    /// Escape cancels, unless mention suggestions have it.
    let escapes: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Metrics.s) {
            Image(systemName: "pencil")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
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
            .keyboardShortcut(escapes ? .cancelAction : nil)
            .help("Cancel editing")
            .accessibilityLabel("Cancel editing")
        }
        .frame(height: 36)
        .padding(.horizontal, Metrics.xs)
    }
}

private struct ReplyPreview: View {
    let message: MessageRecord
    let model: AppModel
    /// Escape cancels, unless mention suggestions have it.
    let escapes: Bool
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
            .keyboardShortcut(escapes ? .cancelAction : nil)
            .accessibilityLabel("Cancel reply")
        }
        .frame(height: 36)
        .padding(.horizontal, Metrics.xs)
    }
}
