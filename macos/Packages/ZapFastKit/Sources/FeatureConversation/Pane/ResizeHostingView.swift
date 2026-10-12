import AppKit
import OSLog
import SwiftUI

/// Count-only layout intervals distinguish the native pane's small SwiftUI
/// islands. No chat identity, text or other user content is recorded.
final class ResizeHostingView: NSHostingView<AnyView> {
    private static let signposter = OSSignposter(subsystem: "ZapFast", category: .pointsOfInterest)
    private var layoutName: StaticString = "IslandLayout"
    private var passive = false

    convenience init(layoutName: StaticString, passive: Bool = false) {
        self.init(rootView: AnyView(EmptyView()))
        self.layoutName = layoutName
        self.passive = passive
    }

    override func layout() {
        let interval = Self.signposter.beginInterval(layoutName)
        super.layout()
        Self.signposter.endInterval(layoutName, interval)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passive ? nil : super.hitTest(point)
    }
}
