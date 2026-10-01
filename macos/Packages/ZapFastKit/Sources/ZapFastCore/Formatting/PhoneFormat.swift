import Foundation
import PhoneNumberKit
import ZapFastBridge

/// Phone numbers as WhatsApp writes them, by libphonenumber's rules for each
/// country ("+98 937 039 6614", "+998 90 123 45 67", "+7 912 345-67-89"),
/// where upstream's `phone_of` groups the digits by threes.
public enum PhoneFormat {
    /// The number of a phone-number id ("989370396614@s.whatsapp.net"), or
    /// nil for a group, a channel or a privacy id. Upstream decides which
    /// ids are phone numbers; the digits come from the id, as upstream's
    /// own format drops Brazil's country code.
    public static func display(id: String) -> String? {
        guard let upstream = phoneOf(id: id), let digits = id.split(separator: "@").first else { return nil }
        return international(digits: String(digits)) ?? upstream
    }

    /// "+<country> <national>", or nil when libphonenumber does not know
    /// the number's country.
    public static func international(digits: String) -> String? {
        if let known = formatted[digits] { return known }
        let number = try? utility.parse("+" + digits)
        let text = number.map { utility.format($0, toType: .international) }
        formatted[digits] = text
        return text
    }

    /// Its metadata loads once, the first time a number is shown.
    private static let utility = PhoneNumberUtility()
    /// Names and numbers are asked for each time a chat's rows are made.
    private static var formatted: [String: String?] = [:]
}
