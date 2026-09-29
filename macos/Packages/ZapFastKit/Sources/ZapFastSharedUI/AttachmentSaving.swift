import AppKit
import UniformTypeIdentifiers

/// Copies of downloaded attachments, made where the person chooses: the
/// native Save panel and the pasteboard stand in for upstream's own picker.
public enum AttachmentSaving {
    /// Asks where to save a copy of `url` and copies it there, replacing a
    /// file the person chose to replace.
    public static func saveCopy(of url: URL, named name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = true
        }
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: copyToTemporary(url))
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Puts a picture on the pasteboard, as an image rather than a file.
    public static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// `replaceItemAt` moves its source, so it gets a copy.
    private static func copyToTemporary(_ url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "zapfast-save-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
