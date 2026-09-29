import SwiftUI

/// Stacks a bubble's parts top to bottom. The bubble is as wide as its
/// widest part wants to be, up to the width on offer, so short messages
/// stay short; then every part is laid out at that width (a quote fills
/// it, text wraps in it). Parts marked `.bubbleTrailing()` sit on the
/// trailing edge, as the time does.
struct BubbleStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = contentWidth(proposal: proposal, subviews: subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        for subview in subviews {
            let size = subview.sizeThatFits(offer)
            let x = subview[BubbleTrailingKey.self] ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), proposal: offer)
            y += size.height + spacing
        }
    }

    private func contentWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let limit = proposal.width ?? .infinity
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(ideal, limit)
    }
}

nonisolated private struct BubbleTrailingKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Places this part of a bubble on its trailing edge.
    func bubbleTrailing() -> some View {
        layoutValue(key: BubbleTrailingKey.self, value: true)
    }
}
