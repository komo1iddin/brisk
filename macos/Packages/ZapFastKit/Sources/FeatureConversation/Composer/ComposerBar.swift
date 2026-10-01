import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Reply preview, attach button, message field, and send button.
struct ComposerBar: View {
    let chatID: String
    @Bindable var model: AppModel

    /// One line as the text view will measure it, so the empty field's
    /// placeholder does not settle a point higher once the first line is measured.
    @State private var fieldHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize)) + 8
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

            if let preparing = model.preparingMedia[chatID] {
                PreparingStrip(count: preparing)
                    .modifier(ComposerPanelSurface())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let staged = model.attachments[chatID], !staged.isEmpty, !model.isEditingMedia(in: chatID),
               !model.recorder.isRecording {
                AttachmentStrip(attachments: staged) { id in
                    withAnimation(.zf(reduceMotion)) { model.removeAttachment(id, in: chatID) }
                }
                .modifier(ComposerPanelSurface())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The two share one shape, so they only cross-fade.
            if model.recorder.isRecording {
                RecordingBar(recorder: model.recorder) {
                    model.cancelRecording()
                } togglePause: {
                    model.toggleRecordingPause()
                } togglePreview: {
                    model.toggleRecordingPreview()
                } send: {
                    model.sendRecording(in: chatID)
                }
                .transition(.opacity)
            } else {
                editor
                    .transition(.opacity)
            }
        }
        .animation(.zf(reduceMotion, duration: 0.18), value: model.recorder.isRecording)
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
        GlassGroup(spacing: Metrics.s) {
            HStack(alignment: .bottom, spacing: Metrics.s) {
                Button {
                    attaching.toggle()
                } label: {
                    Label("Attach", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: Self.control, height: Self.control)
                        .rotationEffect(.degrees(attaching && !reduceMotion ? 45 : 0))
                        .animation(.zf(reduceMotion), value: attaching)
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
    fileprivate static let control: CGFloat = 22
    /// The field's inside height for one line: with its padding, as tall
    /// as the round buttons beside it.
    fileprivate static let fieldLine: CGFloat = 30

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
                        .font(.system(size: NSFont.systemFontSize * model.preferences.textScale))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                        // The field itself is labelled "Message".
                        .accessibilityHidden(true)
                }
                ComposerTextView(
                    text: textBinding,
                    height: $fieldHeight,
                    focusToken: "\(chatID)#\(model.composerFocusRequests)",
                    maxHeight: 180,
                    enterSends: model.preferences.enterSends,
                    textScale: model.preferences.textScale,
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

/// While recording, in the editor's own shape so nothing jumps: the bin
/// where + was, a field holding a red dot, the time and the live meter,
/// pause where the microphone was, and send. Paused, the dot becomes a
/// play button to listen back and pause becomes a microphone to go on. A
/// take of ten seconds or more asks before it is discarded, Escape
/// included.
private struct RecordingBar: View {
    let recorder: VoiceRecorder
    let cancel: () -> Void
    let togglePause: () -> Void
    let togglePreview: () -> Void
    let send: () -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        GlassGroup(spacing: Metrics.s) {
            HStack(alignment: .bottom, spacing: Metrics.s) {
                Button {
                    if recorder.elapsed() >= AppModel.discardAskAfter {
                        confirmingDiscard = true
                    } else {
                        cancel()
                    }
                } label: {
                    Label("Discard Recording", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: ComposerBar.control, height: ComposerBar.control)
                }
                .composerButton()
                .keyboardShortcut(.cancelAction)
                .help("Discard recording")
                .confirmationDialog(
                    Text("Discard this voice message?"),
                    isPresented: $confirmingDiscard
                ) {
                    Button("Discard", role: .destructive, action: cancel)
                } message: {
                    Text("\(Self.time(recorder.elapsed())) recorded will be lost.")
                }

                field

                Button(action: togglePause) {
                    Label(
                        recorder.isPaused ? "Resume Recording" : "Pause Recording",
                        systemImage: recorder.isPaused ? "mic.fill" : "pause.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: ComposerBar.control, height: ComposerBar.control)
                    .contentTransition(.symbolEffect(.replace))
                }
                .composerButton()
                .foregroundStyle(recorder.isPaused ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .help(recorder.isPaused ? "Go on recording" : "Pause recording")

                Button(action: send) {
                    Label("Send Voice Message", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: ComposerBar.control, height: ComposerBar.control)
                }
                .composerButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .help("Send voice message")
            }
        }
    }

    /// The editor's field, one line tall: the dot (or play), the time, the meter.
    private var field: some View {
        HStack(spacing: Metrics.s) {
            if recorder.isPaused {
                Button(action: togglePreview) {
                    Label(
                        recorder.isPreviewing ? "Stop" : "Play Recording",
                        systemImage: recorder.isPreviewing ? "stop.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13))
                    .frame(width: 14, height: 14)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help(recorder.isPreviewing ? "Stop playing" : "Listen to the recording so far")
            } else {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .symbolEffectPulseIfAvailable()
                    .frame(width: 14, height: 14)
            }

            // Ticks only while the time moves; a paused take stays still.
            TimelineView(.animation(minimumInterval: 0.25, paused: recorder.isPaused && !recorder.isPreviewing)) { context in
                Text(Self.time(shownTime(at: context.date)))
                    .font(.body.monospacedDigit())
            }

            LevelMeter(recorder: recorder)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
        }
        .frame(height: ComposerBar.fieldLine)
        .padding(.leading, Metrics.m)
        .padding(.trailing, Metrics.m)
        .padding(.vertical, Metrics.xxs + 1)
        .modifier(ComposerFieldSurface())
    }

    /// The length recorded, or while listening back, how far it has played.
    private func shownTime(at now: Date) -> TimeInterval {
        let elapsed = recorder.elapsed(at: now)
        guard let started = recorder.previewStarted else { return elapsed }
        return min(elapsed, now.timeIntervalSince(started))
    }

    private static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

/// The take's loudness as the phone draws it: thin rounded bars at a fixed
/// pitch entering at the right and sliding left, newest on the right;
/// quiet moments are dots, and the room not yet recorded a faint line.
/// Each bar glides in over the time until the next level, so the strip
/// moves smoothly rather than a step at a time.
private struct LevelMeter: View {
    let recorder: VoiceRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bar: CGFloat = 3
    private static let pitch: CGFloat = 5
    /// Below this a moment counts as silence and draws as a dot.
    private static let quiet: Float = 0.1

    var body: some View {
        let levels = recorder.levels
        let still = recorder.isPaused || reduceMotion
        TimelineView(.animation(paused: still)) { context in
            Canvas { canvas, size in
                let slide = still ? 1 : progress(at: context.date)
                draw(levels, slide: slide, in: &canvas, size: size)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    /// How far the newest bar has come in, 0 as it arrives, 1 when the
    /// next is due.
    private func progress(at now: Date) -> CGFloat {
        guard let last = recorder.lastLevelAt else { return 1 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(last) / recorder.levelInterval)))
    }

    private func draw(_ levels: [Float], slide: CGFloat, in canvas: inout GraphicsContext, size: CGSize) {
        let middle = size.height / 2
        let count = Int(size.width / Self.pitch) + 2
        let shown = levels.suffix(count)
        var oldest = size.width
        // From the newest, right to left.
        for (age, level) in shown.reversed().enumerated() {
            let x = size.width - (CGFloat(age) + slide) * Self.pitch
            oldest = x
            if level < Self.quiet {
                let dot = CGRect(x: x + 0.25, y: middle - 1.25, width: 2.5, height: 2.5)
                canvas.fill(Path(ellipseIn: dot), with: .color(.secondary))
            } else {
                let height = max(5, size.height * CGFloat(level))
                let rect = CGRect(x: x, y: middle - height / 2, width: Self.bar, height: height)
                canvas.fill(Path(roundedRect: rect, cornerRadius: Self.bar / 2), with: .color(.secondary))
            }
        }
        if oldest > Self.pitch {
            let rest = CGRect(x: 0, y: middle - 0.5, width: oldest - Self.pitch + Self.bar, height: 1)
            canvas.fill(Path(rest), with: .color(.secondary.opacity(0.35)))
        }
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
            .onAppear(perform: pulse)
            // Turning Reduce Motion on stops a pulse already running.
            .onChange(of: reduceMotion) { pulse() }
    }

    private func pulse() {
        if reduceMotion {
            withAnimation(nil) { dim = false }
        } else {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// Photos and videos being made ready to send (redrawn at their quality,
/// or re-encoded), until each goes to WhatsApp.
private struct PreparingStrip: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Metrics.s) {
            ProgressView().controlSize(.small)
            Text(count == 1 ? "Preparing 1 item to send…" : "Preparing \(count) items to send…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
        }
        .frame(height: 30)
        .padding(.horizontal, Metrics.xs)
        .animation(.zf(reduceMotion), value: count)
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
        let nameColor = Palette.name(model.chats.nameColor(message.sender, in: message.chat))
        HStack(spacing: Metrics.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(nameColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(model.chats.displayName(message.sender, hint: message.senderName))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(nameColor)
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
