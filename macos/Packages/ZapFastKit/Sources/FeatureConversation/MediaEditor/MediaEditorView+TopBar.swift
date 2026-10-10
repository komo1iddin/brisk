/// The editor's top bar: what it offers while browsing, while cropping,
/// and while writing on a picture.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension MediaEditorView {
    var topBar: some View {
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

    func doneButton(_ action: @escaping () -> Void) -> some View {
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
}
