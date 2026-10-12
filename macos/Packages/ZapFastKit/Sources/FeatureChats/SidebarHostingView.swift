import AppKit
import OSLog
import SwiftUI

/// Count-only intervals for the sidebar's optional SwiftUI islands.
final class SidebarHostingView: NSHostingView<AnyView> {
    private static let signposter = OSSignposter(subsystem: "ZapFast", category: .pointsOfInterest)
    private var layoutName: StaticString = "SidebarIslandLayout"
    private var passive = false

    convenience init(layoutName: StaticString, passive: Bool = false) {
        self.init(rootView: AnyView(EmptyView()))
        self.layoutName = layoutName
        self.passive = passive
    }

    override var isHidden: Bool {
        didSet {
            if oldValue && !isHidden { needsLayout = true }
        }
    }

    override func layout() {
        guard !isHidden else { return }
        let interval = Self.signposter.beginInterval(layoutName)
        super.layout()
        Self.signposter.endInterval(layoutName, interval)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passive ? nil : super.hitTest(point)
    }
}
