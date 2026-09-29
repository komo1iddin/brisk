import Foundation
import Observation
import ZapFastBridge

/// Profile pictures on disk, fetched on first use.
@Observable
public final class AvatarStore {
    private var paths: [String: URL] = [:]
    /// Ids already asked for, with or without an answer, so scrolling a list
    /// does not ask twice.
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let send: (BridgeCommand) -> Void

    init(send: @escaping (BridgeCommand) -> Void) {
        self.send = send
    }

    /// The thumbnail for `id`, asking the backend for it the first time.
    public func url(for id: String) -> URL? {
        if let url = paths[id] {
            return url
        }
        if requested.insert(id).inserted {
            send(.fetchAvatar(id: id, full: false))
        }
        return nil
    }

    func apply(id: String, full: Bool, path: String?) {
        guard !full else { return }
        paths[id] = path.map { URL(filePath: $0) }
    }

    /// Asks again after reconnecting: earlier failures may have been offline.
    func forgetMisses() {
        requested = Set(paths.keys)
    }

    func clear() {
        paths = [:]
        requested = []
    }
}
