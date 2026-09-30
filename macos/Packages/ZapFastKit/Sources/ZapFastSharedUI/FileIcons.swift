import AppKit
import ZapFastCore

/// The icon the Finder shows for a kind of file (Excel's for a spreadsheet,
/// Word's for a document, when they are installed).
public enum FileIcons {
    public static func icon(fileName: String, mime: String) -> NSImage {
        NSWorkspace.shared.icon(for: DocumentType.of(fileName: fileName, mime: mime))
    }
}
