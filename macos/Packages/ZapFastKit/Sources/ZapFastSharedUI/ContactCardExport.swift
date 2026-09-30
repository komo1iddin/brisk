import AppKit

/// Hands a shared contact card to the Contacts app, which asks before
/// adding it. The card is written to a temporary `.vcf` for that.
public enum ContactCardExport {
    public static func openInContacts(vcard: String, name: String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ZapFast Contacts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.replacing(/[\/:\\\\]/, with: "-").trimmingCharacters(in: .whitespaces)
        let file = folder.appending(path: "\(safe.isEmpty ? "Contact" : safe).vcf")
        guard (try? vcard.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        if let contacts = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") {
            NSWorkspace.shared.open([file], withApplicationAt: contacts, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
