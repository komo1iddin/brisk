/// What the editor's controls do: the bindings behind the caption, and
/// every edit, crop, overlay and key the editor acts on.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension MediaEditorView {
    var showsStrip: Bool {
        state.mode == .draw && state.brush != .pixelate || state.mode == .text
    }

    var availableBrushes: [MediaStroke.Brush] {
        current?.media == .photo ? MediaStroke.Brush.allCases : MediaStroke.Brush.allCases.filter { $0 != .pixelate }
    }

    var colorBinding: Binding<MediaColor> {
        Binding(
            get: { state.mode == .text ? (state.draftText?.color ?? .white) : state.drawColor },
            set: { color in
                if state.mode == .text { state.draftText?.color = color } else { state.drawColor = color }
            }
        )
    }

    var draftTextBinding: Binding<String> {
        Binding(
            get: {
                if case .text(let text) = state.draftText?.content { text } else { "" }
            },
            set: { state.draftText?.content = .text($0) }
        )
    }

    func captionBinding(_ id: Attachment.ID) -> Binding<String> {
        Binding(
            get: { model.attachments[chatID]?.first { $0.id == id }?.caption ?? "" },
            set: { model.setCaption($0, for: id, in: chatID) }
        )
    }

    var aspectBinding: Binding<CropAspect> {
        Binding(get: { state.aspect }, set: { choose(aspect: $0, portrait: state.portrait) })
    }

    var portraitBinding: Binding<Bool> {
        Binding(get: { state.portrait }, set: { choose(aspect: state.aspect, portrait: $0) })
    }

    func bindMentions() {
        let chat = chatID, model = model
        mentions.candidates = { model.mentionCandidates(in: chat, query: $0) }
        mentions.onPick = { model.addMention($0, in: chat) }
        emoji.candidates = { model.emojiSuggestions(for: $0) }
        emoji.onPick = { model.rememberEmoji($0) }
    }

    // MARK: Actions

    /// Changes the current item's edit, as one undo step unless cropping
    /// (a crop is one step when it is done).
    func change(recorded: Bool = true, animated: Bool = true, _ transform: (inout MediaEdit) -> Void) {
        guard let current else { return }
        var edit = current.edit
        transform(&edit)
        guard edit != current.edit else { return }
        if recorded, state.mode != .crop { state.record(current.edit, for: current.id) }
        withAnimation(animated ? .zf(reduceMotion, duration: 0.25) : nil) {
            model.setEdit(edit, for: current.id, in: chatID)
        }
    }

    func select(_ id: Attachment.ID) {
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

    func undo() {
        guard let current, let previous = state.undo(current.edit, for: current.id) else { return }
        withAnimation(.zf(reduceMotion)) { model.setEdit(previous, for: current.id, in: chatID) }
    }

    func redo() {
        guard let current, let next = state.redo(current.edit, for: current.id) else { return }
        withAnimation(.zf(reduceMotion)) { model.setEdit(next, for: current.id, in: chatID) }
    }

    func send() {
        if state.mode == .text { commitText() }
        state.pauseAll()
        withAnimation(.zf(reduceMotion, duration: 0.22)) { model.sendMedia(in: chatID) }
    }

    func close() {
        if staged.contains(where: { !$0.edit.isEmpty }) {
            confirmingDiscard = true
        } else {
            discard()
        }
    }

    func discard() {
        state.pauseAll()
        withAnimation(.zf(reduceMotion, duration: 0.22)) { model.discardAttachments(in: chatID) }
    }

    func startCropping() {
        guard let current else { return }
        state.selectedOverlay = nil
        state.editBeforeCrop = current.edit
        state.aspect = .free
        state.mode = .crop
    }

    func finishCropping() {
        if let current, let before = state.editBeforeCrop, before != current.edit {
            state.record(before, for: current.id)
        }
        state.editBeforeCrop = nil
        state.mode = .browse
    }

    func cancelCropping() {
        if let current, let before = state.editBeforeCrop {
            withAnimation(.zf(reduceMotion, duration: 0.25)) { model.setEdit(before, for: current.id, in: chatID) }
        }
        state.editBeforeCrop = nil
        state.mode = .browse
    }

    func choose(aspect: CropAspect, portrait: Bool) {
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

    func startText() {
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

    func rewriteText(_ overlay: MediaOverlay) {
        state.selectedOverlay = nil
        state.draftText = overlay
        state.draftIsNew = false
        state.mode = .text
    }

    func commitText() {
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

    func addEmoji(_ picked: String) {
        guard !picked.isEmpty else { return }
        let overlay = MediaOverlay(
            content: .emoji(picked),
            center: visibleCenter,
            size: Double(72 / max(state.displayLongSide, 1))
        )
        change { $0.overlays.append(overlay) }
        state.selectedOverlay = overlay.id
    }

    func handleKey(_ key: EditorKeys.Key, inTextField: Bool) -> Bool {
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

    func qualityDetails(_ current: Attachment) -> [MediaQuality: String] {
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
