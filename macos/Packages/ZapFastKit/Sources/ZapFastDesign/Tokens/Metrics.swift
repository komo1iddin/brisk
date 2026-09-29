import CoreGraphics
import SwiftUI

/// One scale for spacing, radii and sizes, so screens cannot drift apart.
public enum Metrics {
    // Spacing
    public static let hairline: CGFloat = 1
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24

    // Radii
    public static let bubbleRadius: CGFloat = 16
    public static let controlRadius: CGFloat = 8
    public static let cardRadius: CGFloat = 12

    // Sizes
    public static let rowAvatar: CGFloat = 40
    public static let headerAvatar: CGFloat = 28
    /// Bubbles stop at this share of the timeline's width.
    public static let bubbleMaxWidthFraction: CGFloat = 0.72
    public static let bubbleMaxWidth: CGFloat = 560
}

extension Animation {
    /// The app's one easing, off when Reduce Motion is on.
    public static func zf(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }
}
