import Foundation
import Observation
import ZapFastBridge

/// Profile pictures on disk, fetched on first use.
@Observable
public final class AvatarStore {
    private var paths: [String: URL] = [:]
    /// Full-size pictures, for the info panel.
    private var fullPaths: [String: URL] = [:]
    /// Bumped each time a picture arrives for an id, so views reload one
    /// written over the old file (our new profile picture).
    private var versions: [String: Int] = [:]
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

    public func version(for id: String) -> Int {
        versions[id, default: 0]
    }

    /// The full-size picture for `id`, asking for it the first time.
    public func fullURL(for id: String) -> URL? {
        if let url = fullPaths[id] {
            return url
        }
        if requested.insert("full:\(id)").inserted {
            send(.fetchAvatar(id: id, full: true))
        }
        return nil
    }

    func apply(id: String, full: Bool, path: String?) {
        let url = path.map { URL(filePath: $0) }
        if full { fullPaths[id] = url } else { paths[id] = url }
        versions[id, default: 0] += 1
    }

    /// Asks again after reconnecting: earlier failures may have been offline.
    func forgetMisses() {
        requested = Set(paths.keys).union(fullPaths.keys.map { "full:\($0)" })
    }

    func clear() {
        paths = [:]
        fullPaths = [:]
        versions = [:]
        requested = []
    }
}
