import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Reply preview, attach button, message field, and send button.
struct ComposerBar: View {
    let chatID: String
    @Bindable var model: AppModel

    @State private var fieldHeight: CGFloat = 22
    @State private var choosing: FileChoice?
    @State private var attaching = false
    @State private var pickingSticker = false
    @State private var makerPicture: StickerPicture?
    @State private var mentions = MentionTracker()
    @State private var emoji = EmojiTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let completing = !emoji.suggestions.isEmpty
        let suggesting = completing || !mentions.suggestions.isEmpty
        VStack(spacing: Metrics.s) {
            if completing {
                EmojiSuggestions(tracker: emoji)
                    .transition(.opacity)
            } else if suggesting {
                MentionSuggestions(tracker: mentions, model: model)
                    .transition(.opacity)
            }
            if let message = model.editing[chatID] {
                EditPreview(message: message, escapes: !suggesting) {
                    withAnimation(.zf(reduceMotion)) { model.cancelEditing(in: chatID) }
                }
                .modifier(ComposerPanelSurface())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let reply = model.replyingTo[chatID] {
                ReplyPreview(message: reply, model: model, escapes: !suggesting) {
                    withAnimation(.zf(reduceMotion)) { model.cancelReply(in: chatID) }
                }
                .modifier(ComposerPanelSurface())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let unsent = model.unsentVoice, unsent.chat == chatID, !model.recorder.isRecording {
                UnsentVoiceStrip(seconds: unsent.seconds) {
                    withAnimation(.zf(reduceMotion)) { model.discardUnsentVoice() }
                }
                .modifier(ComposerPanelSurface())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let staged = model.attachments[chatID], !staged.isEmpty, !model.recorder.isRecording {
                AttachmentStrip(attachments: staged) { id in
                    withAnimation(.zf(reduceMotion)) { model.removeAttachment(id, in: chatID) }
                }
                .modifier(ComposerPanelSurface())
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
        .modifier(ComposerBarSurface())
        .sheet(isPresented: pollSheet) {
            CreatePollSheet(chatID: chatID, model: model)
        }
        .fileImporter(
            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
            allowedContentTypes: choosing == .media ? [.image, .movie] : [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.stage(files: urls, in: chatID) }
        }
        .sheet(item: $makerPicture) { picture in
            StickerMakerSheet(picture: picture, chatID: chatID, model: model)
        }
        .onAppear(perform: bindMentions)
        .onChange(of: chatID) {
            mentions.cancel()
            emoji.cancel()
            bindMentions()
        }
    }

    /// Asks for a picture for the sticker maker.
    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a picture to make a sticker from")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { makerPicture = await StickerPicture.inspect(url) }
    }

    private func bindMentions() {
        let chat = chatID, model = model
        mentions.candidates = { model.mentionCandidates(in: chat, query: $0) }
        mentions.onPick = { model.addMention($0, in: chat) }
        emoji.candidates = { model.emojiSuggestions(for: $0) }
        emoji.onPick = { model.rememberEmoji($0) }
    }

    /// As in Messages: a + button with the attach and create menu, the
    /// field with the stickers button inside it, then Send, or the
    /// microphone while there is nothing to send. System buttons: Liquid
    /// Glass on macOS 26, bordered before it.
    private var editor: some View {
        HStack(alignment: .bottom, spacing: Metrics.s) {
            Button {
                attaching.toggle()
            } label: {
                Label("Attach", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: Self.control, height: Self.control)
                    .rotationEffect(.degrees(attaching ? 45 : 0))
                    .animation(.snappy(duration: 0.2), value: attaching)
            }
            .composerButton()
            .help("Attach photos, videos or documents, or create a poll or sticker")
            .popover(isPresented: $attaching, arrowEdge: .top) {
                AttachPanel(creates: !isEditing) { choice in
                    attaching = false
                    // The panel closes before a file dialog or sheet opens.
                    DispatchQueue.main.async { attach(choice) }
                }
            }

            field

            if isEditing {
                sendButton(title: "Save Changes", systemImage: "checkmark")
                    .disabled(isBlank)
            } else if isBlank, !hasAttachments, model.unsentVoice?.chat == chatID {
                // Send tries the refused voice message again, as upstream's.
                Button {
                    model.resendVoice(in: chatID)
                } label: {
                    Label("Send Voice Message", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: Self.control, height: Self.control)
                }
                .composerButton(prominent: true)
                .help("Send the voice message again")
            } else if isBlank, !hasAttachments {
                Button {
                    model.startRecording()
                } label: {
                    Label("Record Voice Message", systemImage: "mic")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: Self.control, height: Self.control)
                }
                .composerButton()
                .help("Record a voice message")
            } else {
                sendButton(title: "Send", systemImage: "arrow.up")
            }
        }
    }

    private func attach(_ choice: AttachChoice) {
        switch choice {
        case .document: choosing = .files
        case .media: choosing = .media
        case .poll: model.pollComposerChat = chatID
        case .sticker: choosePicture()
        }
    }

    /// The side buttons' size, matching the one-line field.
    private static let control: CGFloat = 22
    /// The field's inside height for one line: with its padding, as tall
    /// as the round buttons beside it.
    private static let fieldLine: CGFloat = 30

    private func sendButton(title: LocalizedStringKey, systemImage: String) -> some View {
        Button {
            model.sendText(in: chatID)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: Self.control, height: Self.control)
        }
        .composerButton(prominent: true)
        .help(title)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Metrics.xs) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(hasAttachments ? "Add a caption" : "Message")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: textBinding,
                    height: $fieldHeight,
                    focusToken: "\(chatID)#\(model.composerFocusRequests)",
                    maxHeight: 180,
                    enterSends: model.preferences.enterSends,
                    onSubmit: { model.sendText(in: chatID) },
                    onEdit: { model.composerEdited(in: chatID) },
                    onPasteFiles: { model.stage(files: $0, in: chatID) },
                    onPasteImage: { picture in
                        if let image = PastedImage(picture) { model.stage(image: image, in: chatID) }
                    },
                    onUpInEmpty: { model.editLastMessage(in: chatID) },
                    onScrollMessages: { model.scrollTimeline($0) },
                    mentions: mentions,
                    emoji: emoji,
                    mentionNames: (model.composerMentions[chatID] ?? []).map(\.name)
                )
                .frame(height: fieldHeight)
            }
            // One line sits centred beside the round buttons.
            .frame(minHeight: Self.fieldLine)

            Button {
                pickingSticker.toggle()
            } label: {
                Label("Stickers and GIFs", systemImage: "face.smiling")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16))
                    .frame(width: 24, height: Self.fieldLine)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stickers and GIFs")
            .disabled(isEditing)
            .popover(isPresented: $pickingSticker, arrowEdge: .top) {
                StickerPicker(chatID: chatID, model: model) {
                    pickingSticker = false
                } makeSticker: {
                    pickingSticker = false
                    choosePicture()
                }
            }
        }
        .padding(.leading, Metrics.m)
        .padding(.trailing, Metrics.xs)
        .padding(.vertical, Metrics.xxs + 1)
        .modifier(ComposerFieldSurface())
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

    private var hasAttachments: Bool {
        !(model.attachments[chatID] ?? []).isEmpty
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

/// What the + menu is choosing files for.
private enum FileChoice {
    case media, files
}

/// On macOS 26 the controls float in glass over the chat; before it they
/// sit on a bar, as in Messages.
private struct ComposerBarSurface: ViewModifier {
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

/// What sits above the field (a reply, an edit, staged files) gets its own
/// glass on macOS 26, where there is no bar under it.
private struct ComposerPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .padding(.horizontal, Metrics.s)
                .padding(.vertical, Metrics.xs)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        } else {
            content
        }
    }
}

private struct ComposerFieldSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.background, in: shape)
                .overlay(shape.strokeBorder(.separator))
        }
    }
}

private extension View {
    /// A round system button beside the field; `prominent` for Send.
    @ViewBuilder
    func composerButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
            } else {
                buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
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
                Label("Discard Recording", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .composerButton()
            .foregroundStyle(.red)
            .keyboardShortcut(.cancelAction)
            .help("Discard recording")

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
                Label("Send Voice Message", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .composerButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .help("Send voice message")
        }
        .padding(.leading, Metrics.xs)
        .frame(minHeight: 34)
        .modifier(ComposerPanelSurface())
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

/// A voice message that could not be sent, above the field until Send
/// tries again or the cross discards it.
private struct UnsentVoiceStrip: View {
    let seconds: Int
    let discard: () -> Void

    var body: some View {
        HStack(spacing: Metrics.s) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .frame(width: 16)
            Text("Voice message (\(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))) not sent")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Spacer()
            Button(action: discard) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Discard voice message")
            .accessibilityLabel("Discard voice message")
        }
        .frame(height: 36)
        .padding(.horizontal, Metrics.xs)
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
