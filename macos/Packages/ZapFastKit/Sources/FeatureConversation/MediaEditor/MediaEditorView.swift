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

    @State var state = MediaEditorState()
    @State var captionHeight: CGFloat = 22
    @State var mentions = MentionTracker()
    @State var emoji = EmojiTracker()
    @State var choosingQuality = false
    @State var choosingEmoji = false
    @State var addingFiles = false
    @State var confirmingDiscard = false
    @FocusState var writing: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(chatID: String, model: AppModel, state: MediaEditorState = MediaEditorState()) {
        self.chatID = chatID
        self.model = model
        _state = State(initialValue: state)
    }

    var staged: [Attachment] { model.attachments[chatID] ?? [] }

    var current: Attachment? {
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
}
