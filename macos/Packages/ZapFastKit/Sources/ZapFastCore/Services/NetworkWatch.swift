import Foundation
import Network

/// What to do about the Mac's network changing while WhatsApp is not
/// connected.
///
/// After failed tries the library waits longer and longer before dialling
/// again, up to fifteen minutes, and nothing tells it the network is back.
/// So when the network returns (or changes to another) while the link is
/// down, the model asks for a reconnect at once, and again a few times at
/// growing gaps if that did not take: a network that has just come up does
/// not always resolve names yet.
struct LinkRecovery {
    enum Step: Equatable {
        case wait
        case reconnect
    }

    /// How a network can differ for our purposes: reachable, and over what.
    struct Network: Equatable {
        var reachable: Bool
        var interfaces: Set<NWInterface.InterfaceType>
    }

    /// Gaps before the follow-up tries after the first one.
    static let followUps: [TimeInterval] = [15, 30, 60]

    private var network: Network?
    private var tried = 0
    private(set) var nextTry: Date?

    /// The network was observed. The first observation is the starting point:
    /// it changes nothing, since the library connects on its own at launch.
    mutating func observe(_ now: Network, connected: Bool, at date: Date) -> Step {
        defer { network = now }
        guard let before = network, before != now else { return .wait }
        guard now.reachable, !connected else {
            nextTry = nil
            return .wait
        }
        tried = 0
        nextTry = date.addingTimeInterval(Self.followUps[0])
        return .reconnect
    }

    /// Time passed: a follow-up try is due if the link is still down.
    mutating func tick(connected: Bool, at date: Date) -> Step {
        guard let due = nextTry else { return .wait }
        guard !connected else {
            nextTry = nil
            return .wait
        }
        guard date >= due else { return .wait }
        tried += 1
        nextTry = tried < Self.followUps.count ? date.addingTimeInterval(Self.followUps[tried]) : nil
        return .reconnect
    }
}

/// Watches the Mac's network and reconnects WhatsApp when it comes back.
@MainActor
final class NetworkWatch {
    private var recovery = LinkRecovery()
    private let monitor: NWPathMonitor
    /// A linked device that is not connected: the only link worth redialling.
    private let needsReconnect: () -> Bool
    private let reconnect: () -> Void
    private var timer: Task<Void, Never>?

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        needsReconnect: @escaping () -> Bool,
        reconnect: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.needsReconnect = needsReconnect
        self.reconnect = reconnect
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let network = LinkRecovery.Network(
                reachable: path.status == .satisfied,
                interfaces: Set(path.availableInterfaces.map(\.type))
            )
            Task { @MainActor in self?.observe(network) }
        }
        monitor.start(queue: DispatchQueue(label: "ZapFast.NetworkWatch", qos: .utility))
    }

    func stop() {
        monitor.cancel()
        timer?.cancel()
    }

    func observe(_ network: LinkRecovery.Network, at date: Date = .now) {
        act(on: recovery.observe(network, connected: !needsReconnect(), at: date))
        scheduleFollowUp()
    }

    private func act(on step: LinkRecovery.Step) {
        if step == .reconnect { reconnect() }
    }

    /// Wakes once, when the next follow-up is due.
    private func scheduleFollowUp() {
        timer?.cancel()
        guard let due = recovery.nextTry else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            act(on: recovery.tick(connected: !needsReconnect(), at: .now))
            scheduleFollowUp()
        }
    }
}
