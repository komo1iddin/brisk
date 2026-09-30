import Foundation
import UniformTypeIdentifiers

/// What kind of file a document is: from the name it was sent with, which
/// the Finder would go by, or failing that its MIME type.
public nonisolated enum DocumentType {
    public static func of(fileName: String, mime: String) -> UTType {
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic { return type }
        return UTType(mimeType: mime) ?? .data
    }
}
