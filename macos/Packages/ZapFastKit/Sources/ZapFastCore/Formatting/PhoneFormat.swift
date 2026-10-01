import Foundation
import PhoneNumberKit
import ZapFastBridge

/// Phone numbers as WhatsApp writes them, by libphonenumber's rules for each
/// country ("+98 937 039 6614", "+998 90 123 45 67", "+7 912 345-67-89"),
/// where upstream's `phone_of` groups the digits by threes.
public nonisolated enum PhoneFormat {
    /// The number of a phone-number id ("989370396614@s.whatsapp.net"), or
    /// nil for a group, a channel or a privacy id. Upstream decides which
    /// ids are phone numbers; the digits come from the id, as upstream's
    /// own format drops Brazil's country code.
    public static func display(id: String) -> String? {
        guard let upstream = phoneOf(id: id), let digits = id.split(separator: "@").first else { return nil }
        return international(digits: String(digits)) ?? upstream
    }

    /// "+<country> <national>", or nil when libphonenumber does not know
    /// the number's country. Kept per number: a new one takes about half a
    /// millisecond.
    public static func international(digits: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = formatted[digits] { return known }
        let number = try? utility.parse("+" + digits)
        let text = number.map { utility.format($0, toType: .international) }
        formatted[digits] = text
        return text
    }

    /// Loads libphonenumber's metadata (about 20 ms) off the main thread,
    /// so the first number shown does not wait for it.
    public static func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        _ = utility
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static let utility = PhoneNumberUtility()
    nonisolated(unsafe) private static var formatted: [String: String?] = [:]
}
