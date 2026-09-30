import AppKit
import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Shows the media viewer in a window of its own laid over the chat's
/// window, as WhatsApp does: it covers the sidebar and toolbar, keeps the
/// Mac's light or dark appearance, has its own traffic lights (the red one
/// closes the viewer), and follows the window as it moves and resizes.
struct MediaViewerPresenter: NSViewRepresentable {
    let chatID: String
    let model: AppModel
    let isPresented: Bool
    let theme: ChatTheme

    func makeNSView(context: Context) -> NSView {
        let view = WindowAnchor()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.sync() }
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.dismiss(animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private final class WindowAnchor: NSView {
        var onWindow: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: MediaViewerPresenter
        weak var anchor: NSView?
        private var window: ViewerWindow?
        private var observers: [NSObjectProtocol] = []

        init(parent: MediaViewerPresenter) {
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
            // A chat open in two windows shows one viewer, over the window
            // it was opened from.
            guard let host = anchor?.window, host.isKeyWindow || NSApp.keyWindow == nil,
                  !NSApp.windows.contains(where: { $0 is ViewerWindow && $0.isVisible })
            else { return }
            let content = MediaViewerView(chatID: parent.chatID, model: parent.model)
                .environment(\.chatTheme, parent.theme)
                .tint(parent.theme.accent)
            let window = ViewerWindow(host: host)
            window.delegate = self
            let hosting = NSHostingView(rootView: content)
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(host.frame, display: false)
            window.alphaValue = 0
            host.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            self.window = window

            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let window = self?.window, let host = window.parent, window.frame != host.frame else { return }
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
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            let host = window.parent
            let finish = {
                host?.removeChildWindow(window)
                window.orderOut(nil)
                // Stops the player with the view that owns it.
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

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            parent.model.closeMediaViewer()
            return false
        }
    }
}

/// The viewer's window: titled for the system's corners and traffic lights,
/// with a toolbar's height of title bar that the viewer's header fills.
/// It does not move on its own; its header drags the chat's window, and
/// minimising and zooming act on that window.
final class ViewerWindow: NSWindow {
    init(host: NSWindow) {
        super.init(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        toolbar = NSToolbar(identifier: "MediaViewer")
        toolbarStyle = .unified
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        animationBehavior = .none
        tabbingMode = .disallowed
        title = String(localized: "Media")
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

/// Behind a header's controls: a drag there moves the chat's window (which
/// the covering window follows) and a double-click zooms it, as a title
/// bar does.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            let target = window?.parent ?? window
            if event.clickCount == 2 {
                target?.performZoom(nil)
            } else {
                target?.performDrag(with: event)
            }
        }
    }
}
