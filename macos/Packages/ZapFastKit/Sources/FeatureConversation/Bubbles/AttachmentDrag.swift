import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore

extension View {
    /// A downloaded attachment drags out to the Finder or another app,
    /// under the name it was sent with.
    func draggableAttachment(_ message: MessageRecord) -> some View {
        modifier(AttachmentDrag(message: message))
    }
}

private struct AttachmentDrag: ViewModifier {
    let message: MessageRecord

    func body(content: Content) -> some View {
        if let url = message.mediaURL {
            content.onDrag { Self.provider(for: url, named: name(of: url)) }
        } else {
            content
        }
    }

    /// A document keeps the name it was sent with; other media the file's.
    private func name(of url: URL) -> String {
        if case let .document(_, fileName, _, _) = message.content {
            let clean = fileName.replacing("/", with: "-").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return clean }
        }
        return url.lastPathComponent
    }

    /// Hands over a copy (an APFS clone, so instant), never the file in
    /// ZapFast's own folders, which a drop could otherwise move away.
    private static func provider(for url: URL, named name: String) -> NSItemProvider {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ZapFast Drags", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            return NSItemProvider()
        }
        let provider = NSItemProvider(contentsOf: copy) ?? NSItemProvider()
        provider.suggestedName = name
        return provider
    }
}
