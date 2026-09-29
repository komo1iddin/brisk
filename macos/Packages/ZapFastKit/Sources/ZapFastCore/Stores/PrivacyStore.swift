import Foundation
import Observation
import ZapFastBridge

/// The account's privacy (last seen, online, photo, About, groups, read
/// receipts, calls). Upstream's own `Snapshot` holds the values and the
/// writes in flight; this makes its changes observable.
@Observable
public final class PrivacyStore {
    /// Every category, in the phone's order.
    public let kinds = privacyKinds()

    @ObservationIgnored let snapshot = PrivacySnapshot()
    /// Bumped whenever the snapshot changes, so views re-read it.
    private var version = 0

    public init() {}

    public func choice(_ kind: PrivacyKindInfo) -> PrivacyChoiceInfo? {
        _ = version
        return snapshot.get(kind: kind)
    }

    /// What the picker offers: the phone's choices, plus a value the
    /// account holds that is not offered (such as "My contacts except…").
    public func choices(_ kind: PrivacyKindInfo) -> [PrivacyChoiceInfo] {
        let offered = privacyChoices(kind: kind)
        guard let current = choice(kind), !offered.contains(current) else { return offered }
        return offered + [current]
    }

    public func isPending(_ kind: PrivacyKindInfo) -> Bool {
        _ = version
        return snapshot.pending(kind: kind)
    }

    /// The phone's values are loaded and fresh enough to write against.
    public var isEditable: Bool {
        _ = version
        return snapshot.editable()
    }

    public var fetchFailed: Bool {
        _ = version
        return snapshot.fetchFailed()
    }

    func changed() {
        version += 1
    }
}
