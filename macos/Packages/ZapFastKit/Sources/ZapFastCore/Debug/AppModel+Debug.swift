#if DEBUG
import ZapFastBridge

extension AppModel {
    /// Feeds made-up events to the model, as the backend would, for the
    /// debug scripts that exercise a screen without a linked account.
    public func debugApply(_ events: [BridgeEvent]) {
        apply(events)
    }
}
#endif
