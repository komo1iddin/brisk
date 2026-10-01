import AppKit
import UniformTypeIdentifiers
import ZapFastCore

/// The icon the Finder shows for a kind of file (Excel's for a spreadsheet,
/// Word's for a document, when they are installed).
public enum FileIcons {
    public static func icon(fileName: String, mime: String) -> NSImage {
        NSWorkspace.shared.icon(for: DocumentType.of(fileName: fileName, mime: mime))
    }

    /// The file's kind as WhatsApp draws it in a message: a page in the
    /// kind's colour, its corner folded, with the kind on it (a red PDF, a
    /// blue W, a green X, an orange P), grey with the extension for the
    /// rest. Drawn at whatever scale it lands on, kept per kind.
    @MainActor
    public static func badge(fileName: String, mime: String) -> NSImage {
        let kind = BadgeKind(fileName: fileName, mime: mime)
        if let image = badges[kind] { return image }
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            kind.draw()
            return true
        }
        badges[kind] = image
        return image
    }

    @MainActor private static var badges: [BadgeKind: NSImage] = [:]
}

/// What a badge says and its colour.
nonisolated struct BadgeKind: Hashable {
    let label: String
    /// sRGB, 0xRRGGBB.
    let color: UInt32

    init(fileName: String, mime: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let type = DocumentType.of(fileName: fileName, mime: mime)
        switch ext {
        case "doc", "docx", "docm", "dot", "dotx", "rtf", "odt", "pages":
            (label, color) = ("W", 0x2B6CD8)
        case "xls", "xlsx", "xlsm", "xlt", "xltx", "csv", "ods", "numbers":
            (label, color) = ("X", 0x1F8A4C)
        case "ppt", "pptx", "pptm", "pps", "ppsx", "odp", "key":
            (label, color) = ("P", 0xD9562B)
        case "apk":
            (label, color) = ("APK", 0x3A9C5B)
        case "txt", "md":
            (label, color) = ("TXT", 0x6B7A8F)
        default:
            if type.conforms(to: .pdf) {
                (label, color) = ("PDF", 0xE5363D)
            } else if type.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
                (label, color) = ("ZIP", 0xB58A2E)
            } else if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) {
                (label, color) = (Self.short(ext, or: "AV"), 0x8A5CD6)
            } else if type.conforms(to: .image) {
                (label, color) = (Self.short(ext, or: "IMG"), 0x2E9BB0)
            } else {
                (label, color) = (Self.short(ext, or: ""), 0x8C96A3)
            }
        }
    }

    /// The extension in capitals when it fits on the page.
    private static func short(_ ext: String, or fallback: String) -> String {
        ext.isEmpty || ext.count > 4 ? fallback : ext.uppercased()
    }

    /// In a flipped 32-point square.
    @MainActor
    func draw() {
        let page = CGRect(x: 4.5, y: 1, width: 23, height: 30)
        let radius: CGFloat = 3
        let fold: CGFloat = 7
        let shape = NSBezierPath()
        shape.move(to: CGPoint(x: page.minX + radius, y: page.minY))
        shape.line(to: CGPoint(x: page.maxX - fold, y: page.minY))
        shape.line(to: CGPoint(x: page.maxX, y: page.minY + fold))
        shape.appendArc(from: CGPoint(x: page.maxX, y: page.maxY), to: CGPoint(x: page.minX, y: page.maxY), radius: radius)
        shape.appendArc(from: CGPoint(x: page.minX, y: page.maxY), to: CGPoint(x: page.minX, y: page.minY), radius: radius)
        shape.appendArc(from: CGPoint(x: page.minX, y: page.minY), to: CGPoint(x: page.maxX, y: page.minY), radius: radius)
        shape.close()
        let fill = NSColor(
            srgbRed: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
            blue: CGFloat(color & 0xFF) / 255, alpha: 1
        )
        fill.setFill()
        shape.fill()
        // The folded corner, lighter, with its tip rounded.
        let corner = NSBezierPath()
        corner.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
        corner.line(to: CGPoint(x: page.maxX - fold, y: page.minY + fold - 1.5))
        corner.appendArc(
            from: CGPoint(x: page.maxX - fold, y: page.minY + fold),
            to: CGPoint(x: page.maxX, y: page.minY + fold), radius: 1.5
        )
        corner.line(to: CGPoint(x: page.maxX, y: page.minY + fold))
        corner.close()
        NSColor.white.withAlphaComponent(0.45).setFill()
        corner.fill()
        guard !label.isEmpty else { return }
        let size: CGFloat = switch label.count {
        case 1: 14
        case 2: 9.5
        case 3: 8
        default: 6.5
        }
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let measured = text.size()
        text.draw(at: CGPoint(
            x: page.midX - measured.width / 2,
            y: page.minY + page.height * 0.6 - measured.height / 2
        ))
    }
}
