import AppKit
import SwiftUI

/// A SwiftUI island in an AppKit window that takes no clicks: a picture,
/// a note, or a presenter of sheets that draws nothing itself.
public final class PassiveHostingView: NSHostingView<AnyView> {
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
