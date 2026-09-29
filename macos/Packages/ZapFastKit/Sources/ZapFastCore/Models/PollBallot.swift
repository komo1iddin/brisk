import ZapFastBridge

/// Upstream's poll rules that do not need the backend.
public enum PollBallot {
    /// Our whole choice after clicking option `index` (upstream's
    /// `selection_after_click`): clicking a chosen option withdraws it; a
    /// single-answer poll swaps the choice; a full multi-answer choice
    /// refuses another (nil).
    public static func choices(afterClicking index: UInt32, in state: PollSummary) -> [UInt32]? {
        var choices = state.selected
        if choices.contains(index) {
            choices.removeAll { $0 == index }
        } else {
            if state.selectable == 1 { choices.removeAll() }
            if state.selectable > 0, choices.count >= Int(state.selectable) { return nil }
            choices.append(index)
        }
        return choices.sorted()
    }
}
