import Foundation

/// Where this app keeps its files. Separate from upstream ZapFast's folders,
/// so both can be linked at once without sharing a session.
public struct AppPaths: Sendable {
    public var data: URL
    public var caches: URL

    public init(data: URL, caches: URL) {
        self.data = data
        self.caches = caches
    }

    /// `~/Library/Application Support/<bundle id>` and `~/Library/Caches/<bundle id>`.
    public static func standard(bundle: Bundle = .main) -> AppPaths {
        let name = bundle.bundleIdentifier ?? "ZapFastMac"
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AppPaths(
            data: support.appending(path: name, directoryHint: .isDirectory),
            caches: caches.appending(path: name, directoryHint: .isDirectory)
        )
    }

    public var logFile: URL {
        data.appending(path: "State/zapfast.log")
    }
}
