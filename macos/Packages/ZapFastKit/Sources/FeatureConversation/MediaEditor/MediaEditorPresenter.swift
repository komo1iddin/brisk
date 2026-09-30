import AppKit
import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Shows the media editor in a window of its own laid exactly over the
/// chat's window, as WhatsApp does: it covers the sidebar and the toolbar
/// too, has its own traffic lights (the red one closes the editor), and is
/// always dark, popovers and dialogs included. It follows the window as it
/// moves and resizes, and fades in and out.
struct MediaEditorPresenter: NSViewRepresentable {
    let chatID: String
    let model: AppModel
    let isPresented: Bool
    let theme: ChatTheme

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.sync() }
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.dismiss(animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Reports when it lands in a window, which is where the editor goes.
    final class AnchorView: NSView {
        var onWindow: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: MediaEditorPresenter
        weak var anchor: AnchorView?
        private var window: EditorWindow?
        private var state: MediaEditorState?
        private var observers: [NSObjectProtocol] = []

        init(parent: MediaEditorPresenter) {
            self.parent = parent
        }

        func sync() {
            if parent.isPresented, window == nil {
                present()
            } else if !parent.isPresented, window != nil {
                dismiss(animated: true)
            }
        }

        private func present() {
            guard let host = anchor?.window else { return }
            let state = MediaEditorState()
            self.state = state
            let content = MediaEditorView(chatID: parent.chatID, model: parent.model, state: state)
                .environment(\.chatTheme, parent.theme)
                .tint(parent.theme.accent)
            let window = EditorWindow(host: host)
            window.delegate = self
            let hosting = NSHostingView(rootView: content)
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(host.frame, display: false)
            window.alphaValue = 0
            host.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            self.window = window

            // Follow the chat's window.
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window, let host = window.parent else { return }
                        window.setFrame(host.frame, display: true)
                    }
                })
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                window.animator().alphaValue = 1
            }
        }

        func dismiss(animated: Bool) {
            guard let window else { return }
            self.window = nil
            state?.pauseAll()
            state = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            let host = window.parent
            let finish = {
                host?.removeChildWindow(window)
                window.orderOut(nil)
                window.contentView = nil
                host?.makeKeyAndOrderFront(nil)
            }
            guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                finish()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window.animator().alphaValue = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(170))
                finish()
            }
        }

        /// The red traffic light asks the editor to close, which asks first
        /// when there are edits.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            state?.closeRequests += 1
            return false
        }
    }
}

/// The editor's window: titled for the system's corners and traffic
/// lights, with its content under a transparent title bar. It does not
/// move on its own; minimising and zooming act on the chat's window.
final class EditorWindow: NSWindow {
    init(host: NSWindow) {
        super.init(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Dragging the title bar moves the chat's window (see `sendEvent`).
        isMovable = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(white: 0.04, alpha: 1)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        animationBehavior = .none
        tabbingMode = .disallowed
        title = String(localized: "Send Media")
    }

    /// A press on the title bar, off the traffic lights, drags the chat's
    /// window, which this one follows; a double-click there zooms it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let parent, isInTitleBar(event.locationInWindow) {
            if event.clickCount == 2 {
                parent.performZoom(nil)
            } else {
                parent.performDrag(with: event)
            }
            return
        }
        super.sendEvent(event)
    }

    private func isInTitleBar(_ point: NSPoint) -> Bool {
        let titleBar = frame.height - contentLayoutRect.maxY
        guard point.y >= frame.height - titleBar else { return false }
        return !(contentView?.superview?.hitTest(point) is NSButton)
    }

    override func miniaturize(_ sender: Any?) {
        parent?.miniaturize(sender)
    }

    override func performMiniaturize(_ sender: Any?) {
        parent?.performMiniaturize(sender)
    }

    override func zoom(_ sender: Any?) {
        parent?.zoom(sender)
    }

    override func performZoom(_ sender: Any?) {
        parent?.performZoom(sender)
    }
}
