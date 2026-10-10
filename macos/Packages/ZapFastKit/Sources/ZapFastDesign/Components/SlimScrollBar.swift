import SwiftUI

public extension View {
    /// A SwiftUI scroll view's bar in `SlimScroller`'s look: a slim knob over
    /// the content, no track, shown while the pointer is over the view, and
    /// dragged to scroll. The system's bar is wide when macOS is set to
    /// always show bars, and takes room from the rows. Unlike the chat list's,
    /// the knob is as long as the share of the content in view: these lists
    /// are short, and a short knob over one said there was far more to see.
    func slimScrollBar() -> some View {
        modifier(SlimScrollBar())
    }
}

private struct SlimScrollBar: ViewModifier {
    @State private var geometry = Extent()
    @State private var position = ScrollPosition(edge: .top)
    @State private var hovering = false
    /// Where the content stood when a drag of the knob began.
    @State private var dragFrom: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let knobWidth: CGFloat = 4
    static let shortest: CGFloat = 24
    static let inset: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Extent.self) { scroll in
                Extent(
                    offset: scroll.contentOffset.y + scroll.contentInsets.top,
                    top: scroll.contentInsets.top,
                    content: scroll.contentSize.height,
                    visible: scroll.containerSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom
                )
            } action: { _, extent in
                geometry = extent
            }
            .overlay(alignment: .topTrailing) { knob }
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var knob: some View {
        let extent = geometry
        if extent.visible > 0, extent.content > extent.visible {
            let slot = extent.visible - 2 * Self.inset
            let length = min(max(extent.visible / extent.content * slot, Self.shortest), slot)
            let range = extent.content - extent.visible
            let along = min(1, max(0, extent.offset / range))
            Capsule()
                .fill(Color(nsColor: .labelColor).opacity(dragFrom == nil ? 0.32 : 0.5))
                .frame(width: Self.knobWidth, height: length)
                .padding(.horizontal, 3)
                .contentShape(.rect)
                .offset(y: extent.top + Self.inset + (slot - length) * along)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let from = dragFrom ?? extent.offset
                            dragFrom = from
                            let moved = drag.translation.height * range / max(slot - length, 1)
                            position.scrollTo(y: min(max(from + moved, 0), range))
                        }
                        .onEnded { _ in dragFrom = nil }
                )
                .opacity(hovering || dragFrom != nil ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
        }
    }
}

/// How far a scroll view has scrolled and how much it holds, in points.
private struct Extent: Equatable {
    var offset: CGFloat = 0
    var top: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
}
