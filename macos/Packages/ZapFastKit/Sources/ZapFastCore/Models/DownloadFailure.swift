import Foundation

/// Why a file did not come, from what the backend said, so the person is told
/// what to do about it.
///
/// A download link that WhatsApp has expired makes the backend ask the phone
/// to upload the file again. Whether that worked, the phone stayed silent or
/// the phone no longer has the file are different things to tell: only the
/// first is done, the second is worth trying again once WhatsApp is open on
/// the phone, and the last is final. The backend's words are in
/// `media_failure.rs`; the other texts are the worker's own.
public enum DownloadFailure: Equatable, Sendable {
    /// WhatsApp's servers and the phone no longer have the file.
    case gone
    /// The phone did not answer the request to upload it again.
    case phoneSilent
    /// The phone answered, but could not upload it again.
    case phoneRefused
    /// This Mac was not connected to WhatsApp.
    case offline
    case tooLarge
    /// The download took too long.
    case timedOut
    case other(String)

    public init(_ message: String) {
        let text = message.lowercased()
        if text.contains("did not answer") {
            self = .phoneSilent
        } else if text.contains("could not upload it again") {
            self = .phoneRefused
        } else if text.contains("no longer available") || ["403", "404", "410"].contains(where: text.contains) {
            self = .gone
        } else if text.contains("not connected") {
            self = .offline
        } else if text.contains("64 mib") {
            self = .tooLarge
        } else if text.contains("timed out") {
            self = .timedOut
        } else {
            self = .other(message)
        }
    }

    /// Trying again cannot help.
    public var isFinal: Bool {
        switch self {
        case .gone, .tooLarge: true
        case .phoneSilent, .phoneRefused, .offline, .timedOut, .other: false
        }
    }

    /// Whether the phone is why: waiting for it to be reachable is what helps.
    public var needsPhone: Bool {
        switch self {
        case .phoneSilent, .phoneRefused: true
        case .gone, .offline, .tooLarge, .timedOut, .other: false
        }
    }

    /// What it means and what to do, as a sentence.
    public var explanation: String {
        switch self {
        case .gone:
            String(localized: "This file is no longer on WhatsApp's servers, and your phone does not have it either.")
        case .phoneSilent:
            String(localized: "WhatsApp's servers no longer have this file, and your phone did not answer when asked for it. Open WhatsApp on your phone and try again.")
        case .phoneRefused:
            String(localized: "WhatsApp's servers no longer have this file, and your phone could not upload it again. Try again later.")
        case .offline:
            String(localized: "This Mac is not connected to WhatsApp. It will work once it is.")
        case .tooLarge:
            String(localized: "This file is larger than the 64 MB ZapFast downloads.")
        case .timedOut:
            String(localized: "The download took too long. Try again.")
        case .other(let message):
            message.isEmpty ? String(localized: "The download failed.") : message
        }
    }
}

extension DownloadState {
    /// Why the download failed, if it did.
    public var failure: DownloadFailure? {
        if case .failed(let message) = self { DownloadFailure(message) } else { nil }
    }
}
