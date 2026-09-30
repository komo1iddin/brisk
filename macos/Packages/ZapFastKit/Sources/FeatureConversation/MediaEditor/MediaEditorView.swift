import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Photos and videos about to be sent, over the whole chat, as on the
/// phone: one at a time on a dark stage, with tools to crop and
/// straighten, draw (the pixelate brush hides faces and numbers), write,
/// add emoji, trim and silence a video, and choose the quality; each has
/// its own caption, and the strip below switches between them.
///
/// Escape leaves a tool, then closes (asking first when there are edits);
/// ← → switch items, ⌘Z undoes, Delete removes the picked overlay, all
/// while no text field has the keys.
struct MediaEditorView: View {
    let chatID: String
    @Bindable var model: AppModel

    @State private var state = MediaEditorState()
    @State private var captionHeight: CGFloat = 22
    @State private var mentions = MentionTracker()
    @State private var emoji = EmojiTracker()
    @State private var choosingQuality = false
    @State private var choosingEmoji = false
    @State private var addingFiles = false
    @State private var confirmingDiscard = false
    @FocusState private var writing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(chatID: String, model: AppModel, state: MediaEditorState = MediaEditorState()) {
        self.chatID = chatID
        self.model = model
        _state = State(initialValue: state)
    }

    private var staged: [Attachment] { model.attachments[chatID] ?? [] }

    private var current: Attachment? {
        staged.first { $0.id == state.selectedID } ?? staged.first(where: \.isMedia) ?? staged.first
    }

    var body: some View {
        ZStack {
            // A title bar of its own over the black, as WhatsApp has: the
            // traffic lights sit on it and it drags the window.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Color(white: 0.11)
                        .frame(height: proxy.safeAreaInsets.top)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        }
                    Color(white: 0.04)
                }
                .ignoresSafeArea()
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Under the title bar, as on the phone and in WhatsApp.
                topBar
                    .frame(height: 60)
                    .padding(.horizontal, Metrics.l)
                stageArea
                    .padding(.horizontal, Metrics.xl + (showsStrip ? 32 : 0))
                    .padding(.vertical, Metrics.s)
                    .layoutPriority(1)
                bottomBar
                    .padding(.horizontal, Metrics.l)
                    .padding(.bottom, Metrics.m)
            }
            .overlay(alignment: .trailing) {
                if showsStrip {
                    ColorStrip(color: colorBinding)
                        .id(state.mode)
                        .padding(.trailing, Metrics.m)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.zf(reduceMotion, duration: 0.22), value: state.mode)
        .onChange(of: state.closeRequests) {
            if state.mode == .text { commitText() }
            close()
        }
        .background(EditorKeys(handle: handleKey))
        .task(id: staged.map(\.id)) {
            for attachment in staged { await state.load(attachment) }
        }
        .onAppear {
            model.overlayRenderer = OverlayLabel.render
            if state.selectedID == nil { state.selectedID = current?.id }
            #if DEBUG
            MediaEditorState.debugLatest = state
            state.debugActions = [
                "text": startText, "commit": commitText, "crop": startCropping, "cropDone": finishCropping,
                "emoji": { addEmoji("🎉") }, "undo": undo, "redo": redo,
                "style": {
                    let next = state.draftText?.style.next ?? .plain
                    state.draftText?.style = next
                },
                "align": {
                    let next = state.draftText?.alignment.next ?? .center
                    state.draftText?.alignment = next
                },
                "type": { state.draftText?.content = .text("Hello there") },
                "draw": { state.mode = .draw }, "browse": { state.mode = .browse },
                "rotate": { change(recorded: false) { $0.rotateLeft() } },
            ]
            #endif
            bindMentions()
        }
        .onDisappear { state.pauseAll() }
        // More files dropped on the editor join the ones in it.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.stage(files: files, in: chatID)
            return true
        }
        .onChange(of: staged.map(\.id)) { old, new in
            for gone in Set(old).subtracting(new) { state.forget(gone) }
            if let selected = state.selectedID, !new.contains(selected) {
                let index = old.firstIndex(of: selected) ?? 0
                state.selectedID = new.indices.contains(index) ? new[index] : new.last
                state.mode = .browse
            }
        }
        .onChange(of: state.selectedID) { old, _ in
            if let old { state.videos[old]?.player.pause() }
            state.selectedOverlay = nil
        }
        .fileImporter(isPresented: $addingFiles, allowedContentTypes: [.image, .movie, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.stage(files: urls, in: chatID) }
        }
        .confirmationDialog(
            Text(staged.count == 1 ? "Discard your edits?" : "Discard these \(staged.count) items and your edits?"),
            isPresented: $confirmingDiscard
        ) {
            Button("Discard", role: .destructive) { discard() }
        } message: {
            Text("The caption stays in the message field.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Metrics.s) {
            switch state.mode {
            case .browse:
                Button(action: close) { Image(systemName: "xmark") }
                    .editorButton()
                    .help("Close without sending (Esc)")
                if let current, current.isMedia {
                    undoButtons(current)
                }
                Spacer()
                if let current, current.isMedia {
                    browseTools(current)
                }
            case .crop:
                Spacer()
                cropTools
            case .draw:
                doneButton { state.mode = .browse }
                if let current { undoButtons(current) }
                Spacer()
            case .text:
                doneButton(commitText)
                Spacer()
                textTools
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .transition(.opacity)
    }

    private func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "checkmark").fontWeight(.semibold) }
            .editorButton(prominent: true)
            .help("Done")
    }

    private func undoButtons(_ current: Attachment) -> some View {
        HStack(spacing: Metrics.xs) {
            if state.canUndo(current.id) || state.canRedo(current.id) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .editorButton(diameter: 32)
                    .disabled(!state.canUndo(current.id))
                    .help("Undo (⌘Z)")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .editorButton(diameter: 32)
                    .disabled(!state.canRedo(current.id))
                    .help("Redo (⇧⌘Z)")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .animation(.zf(reduceMotion), value: state.canUndo(current.id) || state.canRedo(current.id))
    }

    @ViewBuilder
    private func browseTools(_ current: Attachment) -> some View {
        Button {
            choosingQuality.toggle()
        } label: {
            QualityBadge(hd: model.preferences.mediaQuality == .hd)
        }
        .editorButton(active: model.preferences.mediaQuality == .hd)
        .help("Media quality")
        .popover(isPresented: $choosingQuality, arrowEdge: .bottom) {
            QualityPicker(
                quality: Binding(get: { model.preferences.mediaQuality }, set: { model.preferences.mediaQuality = $0 }),
                details: qualityDetails(current)
            )
        }

        if current.media == .photo {
            Button { startCropping() } label: { Image(systemName: "crop.rotate") }
                .editorButton()
                .help("Crop and rotate")
        }
        if current.media == .video, state.videos[current.id]?.info.hasSound == true {
            Button {
                change { $0.muted.toggle() }
            } label: {
                Image(systemName: current.edit.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .editorButton(active: current.edit.muted)
            .help(current.edit.muted ? "Send with sound" : "Send without sound")
        }
        Button { choosingEmoji.toggle() } label: { Image(systemName: "face.smiling") }
            .editorButton()
            .help("Add an emoji")
            .popover(isPresented: $choosingEmoji, arrowEdge: .bottom) {
                EmojiCatalog(frequent: model.preferences.reactionEmoji.map(\.emoji), mine: nil) { picked in
                    choosingEmoji = false
                    addEmoji(picked)
                }
            }
        Button { startText() } label: { Image(systemName: "textformat") }
            .editorButton()
            .help("Add text")
        Button {
            state.selectedOverlay = nil
            if current.media == .video, state.brush == .pixelate { state.brush = .pen }
            state.mode = .draw
        } label: { Image(systemName: "pencil.and.scribble") }
            .editorButton()
            .help("Draw")
    }

    private var cropTools: some View {
        HStack(spacing: Metrics.s) {
            Menu {
                Picker("Aspect Ratio", selection: aspectBinding) {
                    Text(CropAspect.free.title).tag(CropAspect.free)
                    Text(CropAspect.original.title).tag(CropAspect.original)
                    Divider()
                    ForEach(CropAspect.presets, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.inline)
                if state.aspect.turns {
                    Divider()
                    Toggle("Portrait", isOn: portraitBinding)
                }
            } label: {
                Image(systemName: "aspectratio")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .editorButton(active: state.aspect != .free)
            .help("Aspect ratio")

            Button {
                change(recorded: false) { $0.mirror() }
            } label: { Image(systemName: "flip.horizontal") }
                .editorButton()
                .help("Flip horizontally")

            Button {
                change(recorded: false) { $0.rotateLeft() }
                if state.aspect.turns { state.portrait.toggle() }
            } label: { Image(systemName: "rotate.left") }
                .editorButton()
                .help("Rotate left")
        }
    }

    private var textTools: some View {
        HStack(spacing: Metrics.s) {
            Button {
                let next = state.draftText?.alignment.next ?? .center
                state.draftText?.alignment = next
            } label: {
                Image(systemName: (state.draftText?.alignment ?? .center).symbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            .editorButton()
            .help("Alignment")
            Button {
                let next = state.draftText?.style.next ?? .plain
                state.draftText?.style = next
            } label: {
                Image(systemName: "character.textbox")
            }
            .editorButton(active: state.draftText?.style != .plain)
            .help("Style: plain, on a label, or on a dark label")
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stageArea: some View {
        if let current {
            VStack(spacing: Metrics.m) {
                ZStack {
                    MediaStage(
                        attachment: current,
                        state: state,
                        begin: { if state.mode != .crop { state.record(current.edit, for: current.id) } },
                        update: { model.setEdit($0, for: current.id, in: chatID) },
                        rewrite: rewriteText
                    )
                    .id(current.id)
                    .transition(.opacity)
                    .simultaneousGesture(TapGesture().onEnded {
                        // Clicking the picture gives the keys to the editor.
                        if state.mode == .browse { NSApp.keyWindow?.makeFirstResponder(nil) }
                    })

                    if current.media == .video, state.mode == .browse, let video = state.videos[current.id], !video.playing {
                        Button { video.togglePlay() } label: {
                            Image(systemName: "play.fill").font(.system(size: 26))
                        }
                        .editorButton(diameter: 64)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .help("Play")
                    }

                    if state.mode == .text {
                        textEditor
                            .transition(.opacity)
                    }
                }
                .animation(.zf(reduceMotion), value: state.videos[current.id]?.playing)

                if state.mode == .crop {
                    StraightenDial(
                        value: current.edit.visibleStraighten,
                        begin: {},
                        change: { degrees in change(recorded: false, animated: false) { $0.visibleStraighten = degrees } }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if current.media == .video, state.mode != .text, let video = state.videos[current.id] {
                    VideoTrimmer(
                        video: video,
                        trim: current.edit.trim,
                        begin: { state.record(current.edit, for: current.id) },
                        change: { trim in
                            var edit = current.edit
                            edit.trim = trim
                            model.setEdit(edit, for: current.id, in: chatID)
                        }
                    )
                    .frame(maxWidth: 640)
                }
            }
            .animation(.zf(reduceMotion, duration: 0.2), value: current.id)
        }
    }

    /// Writing: the picture dimmed and the words large in the middle.
    private var textEditor: some View {
        ZStack {
            Color.black.opacity(0.5)
                .contentShape(.rect)
                .onTapGesture(perform: commitText)
            if let draft = state.draftText {
                TextField("", text: draftTextBinding, prompt: Text("Add text").foregroundStyle(.white.opacity(0.4)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(draft.alignment.textAlignment)
                    .foregroundStyle(draft.style == .label ? (draft.color.isLight ? Color.black : .white) : Color(draft.color))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, draft.style == .plain ? 0 : 12)
                    .padding(.vertical, draft.style == .plain ? 0 : 4)
                    .background {
                        switch draft.style {
                        case .plain: Color.clear
                        case .label: RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(draft.color))
                        case .subtle: RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.5))
                        }
                    }
                    .shadow(color: draft.style == .plain ? .black.opacity(0.35) : .clear, radius: 2, y: 1)
                    .frame(maxWidth: 520)
                    .focused($writing)
                    .onSubmit(commitText)
                    .onAppear { writing = true }
                    .animation(.snappy(duration: 0.15), value: draft.style)
            }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch state.mode {
        case .browse:
            browseBottom
        case .crop:
            HStack {
                Button(action: cancelCropping) { Image(systemName: "xmark") }
                    .editorButton()
                    .help("Cancel")
                Spacer()
                if let current, current.edit.hasGeometry {
                    Button("Reset") {
                        change(recorded: false) { $0.resetGeometry() }
                        state.aspect = .free
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .transition(.opacity)
                }
                Spacer()
                doneButton(finishCropping)
            }
            .frame(height: 48)
        case .draw:
            HStack(spacing: Metrics.l) {
                ForEach(availableBrushes, id: \.self) { brush in
                    Button {
                        state.brush = brush
                    } label: {
                        Image(systemName: brush.symbol)
                    }
                    .editorButton(active: state.brush == brush, diameter: 44)
                    .help(brush.title)
                    .accessibilityLabel(brush.title)
                }
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity)
        case .text:
            Color.clear.frame(height: 56)
        }
    }

    private var browseBottom: some View {
        VStack(spacing: Metrics.m) {
            if let current {
                caption(for: current)
                    .frame(maxWidth: 560)
            }
            HStack(alignment: .center, spacing: Metrics.m) {
                recipient
                    .frame(maxWidth: .infinity, alignment: .leading)
                thumbnails
                    .layoutPriority(1)
                sendButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .transition(.opacity)
    }

    private var recipient: some View {
        Text(model.chats.chat(chatID).map(model.chats.title(for:)) ?? "")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, 7)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: Metrics.controlRadius))
            .help("Sending to this chat")
    }

    private var sendButton: some View {
        Button { send() } label: {
            Image(systemName: "paperplane.fill").font(.system(size: 20))
        }
        .editorButton(prominent: true, diameter: 50)
        .overlay(alignment: .topTrailing) {
            if staged.count > 1 {
                Text(staged.count, format: .number)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.white, in: .capsule)
                    .offset(x: 4, y: -4)
                    .contentTransition(.numericText())
            }
        }
        .help(staged.count > 1 ? "Send \(staged.count) items" : "Send")
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Metrics.s) {
                    ForEach(staged) { attachment in
                        Thumbnail(
                            attachment: attachment,
                            state: state,
                            selected: attachment.id == current?.id,
                            showsRemove: staged.count > 1
                        ) {
                            select(attachment.id)
                        } remove: {
                            withAnimation(.zf(reduceMotion)) { model.removeAttachment(attachment.id, in: chatID) }
                        }
                        .id(attachment.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    Button { addingFiles = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Add photos, videos or files")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: state.selectedID) { _, id in
                withAnimation(.zf(reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func caption(for current: Attachment) -> some View {
        VStack(spacing: Metrics.s) {
            if !emoji.suggestions.isEmpty {
                EmojiSuggestions(tracker: emoji)
                    .transition(.opacity)
            } else if !mentions.suggestions.isEmpty {
                MentionSuggestions(tracker: mentions, model: model)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Metrics.s) {
                ZStack(alignment: .topLeading) {
                    if current.caption.isEmpty {
                        Text("Add a caption")
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: captionBinding(current.id),
                        height: $captionHeight,
                        focusToken: "media#\(current.id)",
                        maxHeight: 120,
                        enterSends: model.preferences.enterSends,
                        onSubmit: send,
                        onEdit: {},
                        onPasteFiles: { model.stage(files: $0, in: chatID) },
                        onPasteImage: { picture in
                            if let image = PastedImage(picture) { model.stage(image: image, in: chatID) }
                        },
                        mentions: mentions,
                        emoji: emoji,
                        mentionNames: (model.composerMentions[chatID] ?? []).map(\.name)
                    )
                    .frame(height: captionHeight)
                }
                .frame(minHeight: 30)
            }
            .padding(.horizontal, Metrics.l)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    // MARK: Bindings

    private var showsStrip: Bool {
        state.mode == .draw && state.brush != .pixelate || state.mode == .text
    }

    private var availableBrushes: [MediaStroke.Brush] {
        current?.media == .photo ? MediaStroke.Brush.allCases : MediaStroke.Brush.allCases.filter { $0 != .pixelate }
    }

    private var colorBinding: Binding<MediaColor> {
        Binding(
            get: { state.mode == .text ? (state.draftText?.color ?? .white) : state.drawColor },
            set: { color in
                if state.mode == .text { state.draftText?.color = color } else { state.drawColor = color }
            }
        )
    }

    private var draftTextBinding: Binding<String> {
        Binding(
            get: {
                if case .text(let text) = state.draftText?.content { text } else { "" }
            },
            set: { state.draftText?.content = .text($0) }
        )
    }

    private func captionBinding(_ id: Attachment.ID) -> Binding<String> {
        Binding(
            get: { model.attachments[chatID]?.first { $0.id == id }?.caption ?? "" },
            set: { model.setCaption($0, for: id, in: chatID) }
        )
    }

    private var aspectBinding: Binding<CropAspect> {
        Binding(get: { state.aspect }, set: { choose(aspect: $0, portrait: state.portrait) })
    }

    private var portraitBinding: Binding<Bool> {
        Binding(get: { state.portrait }, set: { choose(aspect: state.aspect, portrait: $0) })
    }

    private func bindMentions() {
        let chat = chatID, model = model
        mentions.candidates = { model.mentionCandidates(in: chat, query: $0) }
        mentions.onPick = { model.addMention($0, in: chat) }
        emoji.candidates = { model.emojiSuggestions(for: $0) }
        emoji.onPick = { model.rememberEmoji($0) }
    }

    // MARK: Actions

    /// Changes the current item's edit, as one undo step unless cropping
    /// (a crop is one step when it is done).
    private func change(recorded: Bool = true, animated: Bool = true, _ transform: (inout MediaEdit) -> Void) {
        guard let current else { return }
        var edit = current.edit
        transform(&edit)
        guard edit != current.edit else { return }
        if recorded, state.mode != .crop { state.record(current.edit, for: current.id) }
        withAnimation(animated ? .zf(reduceMotion, duration: 0.25) : nil) {
            model.setEdit(edit, for: current.id, in: chatID)
        }
    }

    private func select(_ id: Attachment.ID) {
        guard id != state.selectedID else { return }
        if state.mode == .text { commitText() }
        state.mode = .browse
        withAnimation(.zf(reduceMotion)) { state.selectedID = id }
    }

    private func step(_ offset: Int) {
        guard let current, let index = staged.firstIndex(where: { $0.id == current.id }) else { return }
        let next = index + offset
        guard staged.indices.contains(next) else { return }
        select(staged[next].id)
    }

    private func undo() {
        guard let current, let previous = state.undo(current.edit, for: current.id) else { return }
        withAnimation(.zf(reduceMotion)) { model.setEdit(previous, for: current.id, in: chatID) }
    }

    private func redo() {
        guard let current, let next = state.redo(current.edit, for: current.id) else { return }
        withAnimation(.zf(reduceMotion)) { model.setEdit(next, for: current.id, in: chatID) }
    }

    private func send() {
        if state.mode == .text { commitText() }
        state.pauseAll()
        withAnimation(.zf(reduceMotion, duration: 0.22)) { model.sendMedia(in: chatID) }
    }

    private func close() {
        if staged.contains(where: { !$0.edit.isEmpty }) {
            confirmingDiscard = true
        } else {
            discard()
        }
    }

    private func discard() {
        state.pauseAll()
        withAnimation(.zf(reduceMotion, duration: 0.22)) { model.discardAttachments(in: chatID) }
    }

    private func startCropping() {
        guard let current else { return }
        state.selectedOverlay = nil
        state.editBeforeCrop = current.edit
        state.aspect = .free
        state.mode = .crop
    }

    private func finishCropping() {
        if let current, let before = state.editBeforeCrop, before != current.edit {
            state.record(before, for: current.id)
        }
        state.editBeforeCrop = nil
        state.mode = .browse
    }

    private func cancelCropping() {
        if let current, let before = state.editBeforeCrop {
            withAnimation(.zf(reduceMotion, duration: 0.25)) { model.setEdit(before, for: current.id, in: chatID) }
        }
        state.editBeforeCrop = nil
        state.mode = .browse
    }

    private func choose(aspect: CropAspect, portrait: Bool) {
        state.aspect = aspect
        state.portrait = portrait
        guard let current, let photo = state.photos[current.id] else { return }
        let canvas = current.edit.canvasSize(for: photo.size)
        guard let value = aspect.value(source: canvas, portrait: portrait) else { return }
        change(recorded: false) { edit in
            edit.crop = MediaEdit.crop(aspect: value, canvas: canvas, around: edit.crop)
        }
    }

    /// The middle of what shows, where new words and emoji start.
    private var visibleCenter: CGPoint {
        guard let crop = current?.edit.crop else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: crop.midX, y: crop.midY)
    }

    private func startText() {
        state.selectedOverlay = nil
        state.draftText = MediaOverlay(
            content: .text(""),
            color: .white,
            center: visibleCenter,
            size: Double(34 / max(state.displayLongSide, 1))
        )
        state.draftIsNew = true
        state.mode = .text
    }

    private func rewriteText(_ overlay: MediaOverlay) {
        state.selectedOverlay = nil
        state.draftText = overlay
        state.draftIsNew = false
        state.mode = .text
    }

    private func commitText() {
        defer {
            state.draftText = nil
            state.mode = .browse
        }
        guard let draft = state.draftText, let current else { return }
        var edit = current.edit
        if draft.isEmpty {
            edit.overlays.removeAll { $0.id == draft.id }
        } else if let index = edit.overlays.firstIndex(where: { $0.id == draft.id }) {
            edit.overlays[index] = draft
        } else {
            edit.overlays.append(draft)
        }
        guard edit != current.edit else { return }
        state.record(current.edit, for: current.id)
        model.setEdit(edit, for: current.id, in: chatID)
        if !draft.isEmpty { state.selectedOverlay = draft.id }
    }

    private func addEmoji(_ picked: String) {
        guard !picked.isEmpty else { return }
        let overlay = MediaOverlay(
            content: .emoji(picked),
            center: visibleCenter,
            size: Double(72 / max(state.displayLongSide, 1))
        )
        change { $0.overlays.append(overlay) }
        state.selectedOverlay = overlay.id
    }

    private func handleKey(_ key: EditorKeys.Key, inTextField: Bool) -> Bool {
        switch key {
        case .escape:
            // Suggestions under the caption take Escape first.
            if !mentions.suggestions.isEmpty || !emoji.suggestions.isEmpty { return false }
            if choosingQuality || choosingEmoji || confirmingDiscard { return false }
            switch state.mode {
            case .text: commitText()
            case .draw: state.mode = .browse
            case .crop: cancelCropping()
            case .browse:
                if state.selectedOverlay != nil {
                    state.selectedOverlay = nil
                } else {
                    close()
                }
            }
            return true
        case .delete:
            guard !inTextField, state.mode == .browse, let selected = state.selectedOverlay else { return false }
            change { $0.overlays.removeAll { $0.id == selected } }
            state.selectedOverlay = nil
            return true
        case .left, .right:
            guard !inTextField, state.mode == .browse else { return false }
            step(key == .left ? -1 : 1)
            return true
        case .commandZ, .commandShiftZ:
            guard !inTextField || state.mode == .draw else { return false }
            if key == .commandZ { undo() } else { redo() }
            return true
        default:
            return false
        }
    }

    private func qualityDetails(_ current: Attachment) -> [MediaQuality: String] {
        var details: [MediaQuality: String] = [:]
        for quality in MediaQuality.allCases {
            switch current.media {
            case .photo:
                guard let photo = state.photos[current.id] else { continue }
                let canvas = current.edit.canvasSize(for: photo.original)
                let cropped = CGSize(width: canvas.width * current.edit.crop.width, height: canvas.height * current.edit.crop.height)
                let scale = min(1, CGFloat(quality.photoSide) / max(cropped.width, cropped.height, 1))
                details[quality] = "\(Int((cropped.width * scale).rounded())) × \(Int((cropped.height * scale).rounded()))"
            case .video:
                guard let video = state.videos[current.id] else { continue }
                let size = video.info.size
                let limit = MediaExport.videoSide(quality)
                let scale = min(1, limit / max(size.width, size.height, 1))
                details[quality] = "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded()))"
            case .none:
                break
            }
        }
        return details
    }
}

// MARK: - Pieces

/// "HD" in a rounded box, as WhatsApp draws its quality button.
private struct QualityBadge: View {
    let hd: Bool

    var body: some View {
        Text(verbatim: "HD")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .padding(.horizontal, 3)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.5))
            .accessibilityLabel(hd ? "HD quality" : "Standard quality")
    }
}

/// Standard or HD, with what each means and the size it sends.
private struct QualityPicker: View {
    @Binding var quality: MediaQuality
    let details: [MediaQuality: String]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Media quality").font(.headline)
            Text("HD quality is clearer. Standard quality uses less storage space and is faster to send.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row(.standard, "Standard quality", "Faster to send, smaller file size")
                Divider().padding(.leading, Metrics.m)
                row(.hd, "HD quality", "Slower to send, can be 6 times larger")
            }
            .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
        }
        .padding(Metrics.l)
        .frame(width: 330)
    }

    private func row(_ option: MediaQuality, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { quality = option }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    HStack(spacing: Metrics.xs) {
                        Text(subtitle)
                        if let detail = details[option] {
                            Text(verbatim: "·")
                            Text(verbatim: detail).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if quality == option {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.s + 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One staged item in the strip: its picture, a ring when shown, and a
/// cross under the pointer.
private struct Thumbnail: View {
    let attachment: Attachment
    let state: MediaEditorState
    let selected: Bool
    let showsRemove: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var hovered = false
    private let side: CGFloat = 52

    var body: some View {
        picture
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white, lineWidth: selected ? 2.5 : 0)
            }
            .overlay(alignment: .bottomLeading) {
                if attachment.media == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !attachment.edit.isEmpty {
                    Circle().fill(.yellow).frame(width: 6, height: 6).padding(5)
                        .help("Edited")
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsRemove, hovered {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .transition(.opacity)
                    .help("Remove")
                }
            }
            .scaleEffect(selected ? 1 : 0.9)
            .opacity(selected ? 1 : 0.7)
            .animation(.snappy(duration: 0.18), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var picture: some View {
        switch attachment.media {
        case .photo:
            if let image = state.photos[attachment.id]?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        case .video:
            if let frame = state.videos[attachment.id]?.frames.first {
                Image(decorative: frame, scale: 1).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        case .none:
            ZStack {
                Color.white.opacity(0.08)
                if let url = attachment.fileURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 34, height: 34)
                }
            }
        }
    }
}
