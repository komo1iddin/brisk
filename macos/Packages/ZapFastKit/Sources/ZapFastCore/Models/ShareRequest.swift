import Foundation

/// What the Share menu handed to ZapFast: files and text, waiting for the
/// person to pick the chat whose composer they go to.
public struct ShareRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let files: [URL]
    public let text: String

    /// The Share extension's bundle id; only lists written in its own
    /// container are read.
    static let extensionID = "com.komoliddin.ZapFastMac.Share"

    /// Reads the list a `zapfast-mac://share?list=…` link names, and
    /// removes it. Nil for any other link, or a list from elsewhere.
    static func read(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ShareRequest? {
        guard url.scheme == "zapfast-mac", url.host() == "share",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "list" })?.value
        else { return nil }
        let list = URL(filePath: path).standardizedFileURL
        let container = home.appending(path: "Library/Containers/\(extensionID)/Data", directoryHint: .isDirectory)
            .standardizedFileURL.path(percentEncoded: false)
        guard list.path(percentEncoded: false).hasPrefix(container),
              let data = try? Data(contentsOf: list),
              let shared = try? JSONDecoder().decode(Shared.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: list)
        let files = shared.files.map { URL(filePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        let text = shared.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !files.isEmpty || !text.isEmpty else { return nil }
        return ShareRequest(files: files, text: text)
    }

    private struct Shared: Decodable {
        var files: [String]
        var text: [String]
    }
}
