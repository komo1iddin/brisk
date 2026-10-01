import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore

/// A small floating panel for the call, at the top right of the screen as
/// the Mac shows an incoming FaceTime call. It comes up with the first ring
/// or our call, stays over other windows and Spaces while the call goes,
/// and leaves a moment after it ends. A ringing call also bounces the Dock.
public final class CallWindowController: NSWindowController {
    private let model: AppModel
    private let host: NSHostingView<CallView>
    private var observed = 0
    private var shownSession: UInt64?
    private var attention: Int?

    public init(model: AppModel) {
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Call")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: CallView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        // The panel has no title to keep clear of; the content runs to the top.
        host.safeAreaRegions = []
        self.host = host
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        super.init(window: panel)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func observe() {
        observed += 1
        let round = observed
        let calls = model.calls
        let call = withObservationTracking {
            calls.call
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        show(call)
    }

    private func show(_ call: CallInfo?) {
        guard let window else { return }
        if call?.phase == .ringing {
            if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
        } else if let attention {
            NSApp.cancelUserAttentionRequest(attention)
            self.attention = nil
        }
        guard let call else {
            window.orderOut(nil)
            shownSession = nil
            return
        }
        guard shownSession != call.session else { return }
        shownSession = call.session
        place(window)
        // Over everything, without taking the keyboard from what has it.
        window.orderFrontRegardless()
    }

    /// The top right of the screen with the pointer, clear of the menu bar.
    private func place(_ window: NSWindow) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        window.setContentSize(host.fittingSize)
        let size = window.frame.size
        let margin: CGFloat = 16
        window.setFrameOrigin(NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin))
    }
}
