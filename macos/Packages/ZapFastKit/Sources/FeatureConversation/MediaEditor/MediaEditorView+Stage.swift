/// The stage in the middle of the editor: the picture being edited, and
/// the field that writes on it.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension MediaEditorView {
    @ViewBuilder
    var stageArea: some View {
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
}
