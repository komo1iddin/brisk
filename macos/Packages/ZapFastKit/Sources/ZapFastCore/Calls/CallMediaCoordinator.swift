import Foundation

/// One account may own call capture/playout at a time, including the gap
/// between a successful place/answer request and its first bridge callback.
public final class CallMediaCoordinator {
    static let shared = CallMediaCoordinator()
    private weak var owner: CallStore?
    private struct Client { weak var store: CallStore? }
    private var clients: [Client] = []

    public init() {}

    func register(_ store: CallStore) {
        clients.removeAll { $0.store == nil }
        clients.append(Client(store: store))
    }

    func available(to store: CallStore) -> Bool { owner == nil || owner === store }

    func claim(_ store: CallStore) -> Bool {
        guard available(to: store) else { return false }
        guard owner !== store else { return true }
        owner = store
        for client in clients where client.store !== store { client.store?.mediaOwnershipChanged() }
        return true
    }

    func release(_ store: CallStore) {
        guard owner === store else { return }
        owner = nil
        for client in clients where client.store !== store { client.store?.mediaOwnershipChanged() }
    }
}
