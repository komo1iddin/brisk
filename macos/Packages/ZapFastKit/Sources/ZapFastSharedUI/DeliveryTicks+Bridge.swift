import ZapFastBridge
import ZapFastDesign

extension DeliveryTicks.State {
    /// The ticks for a WhatsApp delivery state; played voice notes read as read.
    public init(_ state: DeliveryState) {
        switch state {
        case .none, .sent: self = .sent
        case .pending: self = .pending
        case .delivered: self = .delivered
        case .read, .played: self = .read
        case .failed: self = .failed
        }
    }
}
