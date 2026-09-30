import AppKit
import UniformTypeIdentifiers

/// The Share menu's ZapFast entry. The extension runs in its own sandbox
/// and cannot reach the linked session, so it only collects what was
/// shared (files, pictures, links, text), writes a small list of it next
/// to the copies it made, and opens ZapFast with that list's path. ZapFast
/// asks which chat it goes to and puts it in that chat's composer; nothing
/// is sent from here.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        // The providers are only read, one at a time, by the loaders below.
        nonisolated(unsafe) let providers = items.flatMap { $0.attachments ?? [] }
        Task { @MainActor in
            let shared = await Self.collect(providers)
            if let manifest = Self.write(shared), let url = Self.handOffURL(manifest) {
                NSWorkspace.shared.open(url)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private struct Shared: Codable, Sendable {
        var files: [String] = []
        var text: [String] = []
    }

    /// A folder of this share's own copies, in the extension's container.
    nonisolated private static let folder: URL = FileManager.default.temporaryDirectory
        .appending(path: "Shared-\(UUID().uuidString)", directoryHint: .isDirectory)

    nonisolated private static func collect(_ providers: [NSItemProvider]) async -> Shared {
        var shared = Shared()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await url(from: provider, type: .fileURL) {
                shared.files.append(url.path(percentEncoded: false))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await url(from: provider, type: .url) {
                shared.text.append(url.absoluteString)
            } else if let type = [UTType.image, .movie].first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }), let copy = await copy(from: provider, type: type) {
                shared.files.append(copy.path(percentEncoded: false))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await text(from: provider) {
                shared.text.append(text)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                      let copy = await copy(from: provider, type: .data) {
                shared.files.append(copy.path(percentEncoded: false))
            }
        }
        return shared
    }

    nonisolated private static func url(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let string as String: continuation.resume(returning: URL(string: string))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                switch item {
                case let string as String: continuation.resume(returning: string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// A picture or video handed over as data: copied while the system's
    /// temporary file still exists.
    nonisolated private static func copy(from provider: NSItemProvider, type: UTType) async -> URL? {
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension
                var base = (name ?? url.deletingPathExtension().lastPathComponent)
                    .replacing("/", with: "-")
                if base.isEmpty { base = "Shared" }
                let target = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    .appending(path: ext.isEmpty ? base : "\(base).\(ext)")
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func write(_ shared: Shared) -> URL? {
        guard !shared.files.isEmpty || !shared.text.isEmpty else { return nil }
        let manifest = folder.appending(path: "share.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(shared).write(to: manifest)
            return manifest
        } catch {
            return nil
        }
    }

    /// `zapfast-mac://share?list=<path>`: only where the list is, never
    /// what was shared.
    nonisolated private static func handOffURL(_ manifest: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "zapfast-mac"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "list", value: manifest.path(percentEncoded: false))]
        return components.url
    }
}
