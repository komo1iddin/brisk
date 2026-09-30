#if DEBUG
import AppKit
import SwiftUI
import ZapFastCore

/// With `ZAPFAST_EDITOR_SCRIPT=text,style,commit,…` the shell opens a
/// window with the media editor over a made-up photo, without starting the
/// backend, runs the named editor actions or `click:x:y` (from the window's
/// top left) a second apart, prints each, and quits: a way to reproduce a
/// crash without clicking. Synthetic drags do not reach SwiftUI's gestures,
/// so drawing and dragging cannot be scripted this way.
public enum MediaEditorScript {
    public static var steps: [String]? {
        ProcessInfo.processInfo.environment["ZAPFAST_EDITOR_SCRIPT"]?.split(separator: ",").map(String.init)
            ?? MediaViewerScript.steps
    }

    /// Also runs `MediaViewerScript` when that is what was asked for.
    @MainActor
    public static func run(model: AppModel) {
        if ProcessInfo.processInfo.environment["ZAPFAST_EDITOR_SCRIPT"] == nil, let steps = MediaViewerScript.steps {
            MediaViewerScript.run(model: model, steps: steps)
            return
        }
        guard let steps else { return }
        _ = MediaEditorGallery.view(mode: "browse", model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1100, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.toolbar = NSToolbar(identifier: "Script")
        window.contentView = NSHostingView(rootView: ScriptHost(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let state = MediaEditorState.debugLatest else { print("script: no editor"); break }
                print("script: \(step)")
                fflush(stdout)
                if let action = state.debugActions[step] {
                    action()
                } else if step == "dump" {
                    let staged = model.attachments["gallery@s.whatsapp.net"] ?? []
                    let current = staged.first { $0.id == state.selectedID }
                    print("script: strokes \(current?.edit.strokes.count ?? 0)")
                    for overlay in current?.edit.overlays ?? [] {
                        print("script: overlay \(overlay.content) at \(overlay.center)")
                    }
                    if let window = NSApp.windows.first(where: { $0 is EditorWindow }) {
                        print("script: window \(window.frame), parent \(String(describing: window.parent?.frame)), content top \(window.contentLayoutRect.maxY)")
                    }
                } else if step.hasPrefix("click:"), let window = NSApp.windows.first(where: { $0 is EditorWindow }) {
                    // click:x:y, from the window's top left, as a real click
                    // would arrive.
                    let parts = step.split(separator: ":").compactMap { Double($0) }
                    let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                        ) { window.sendEvent(event) }
                    }
                    print("script: hit \(String(describing: window.contentView?.superview?.hitTest(point).map { type(of: $0) }))")
                }
                print("script: mode \(state.mode), editing \(model.isEditingMedia(in: "gallery@s.whatsapp.net"))")
                try? await Task.sleep(for: .seconds(1))
            }
            print("script: done")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

private struct ScriptHost: View {
    let model: AppModel

    var body: some View {
        Color.gray
            .background {
                MediaEditorPresenter(
                    chatID: "gallery@s.whatsapp.net", model: model, isPresented: model.isEditingMedia(in: "gallery@s.whatsapp.net"),
                    theme: model.chatTheme(for: nil)
                )
            }
    }
}
#endif
