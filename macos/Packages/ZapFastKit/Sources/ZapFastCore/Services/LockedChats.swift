import Foundation
import Observation
import ZapFastBridge

/// The Locked folder (upstream's locked-chats code): chats WhatsApp's chat
/// lock hides stay out of the list, search, badges and notifications, and
/// open behind a local code that is separate from the phone's. It hides
/// them here; it encrypts nothing. Only upstream's salted verifier of the
/// code is kept, and checks run off the main actor.
@Observable
public final class LockedChats {
    /// The folder is open: the code was entered in this session.
    public internal(set) var isOpen = false
    /// A code is being checked or set.
    public private(set) var checking = false
    /// The last code tried was wrong.
    public private(set) var wrongCode = false

    @ObservationIgnored private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// A local code exists; without one, opening the folder sets it up.
    public var hasCode: Bool {
        preferences.chatLockVerifier != nil
    }

    public var canUseTouchID: Bool {
        hasCode && preferences.unlockWithTouchID && AppLock.touchIDAvailable
    }

    /// Opens the folder with the local code. Returns whether it opened.
    @discardableResult
    public func open(code: String) async -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored = preferences.chatLockVerifier, !code.isEmpty, !checking else { return false }
        checking = true
        let matched = await Self.verifies(stored, code)
        checking = false
        wrongCode = !matched
        if matched { isOpen = true }
        return matched
    }

    public func openWithTouchID(reason: String) async {
        guard canUseTouchID else { return }
        if await AppLock.authenticate(reason: reason) {
            wrongCode = false
            isOpen = true
        }
    }

    /// Sets the first code and opens the folder.
    public func setUp(code: String) async {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasCode, !code.isEmpty, !checking else { return }
        checking = true
        preferences.chatLockVerifier = await Self.verifier(code)
        checking = false
        isOpen = preferences.chatLockVerifier != nil
    }

    public enum CodeError: Error, Equatable, Sendable { case wrongCurrent, mismatch, empty }

    /// Replaces the code, or removes it with an empty `new`; the current
    /// code is asked first. The folder closes either way.
    public func change(current: String, new: String, confirm: String) async -> CodeError? {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new == confirm.trimmingCharacters(in: .whitespacesAndNewlines) else { return .mismatch }
        if let stored = preferences.chatLockVerifier {
            let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard await Self.verifies(stored, current) else { return .wrongCurrent }
        } else if new.isEmpty {
            return .empty
        }
        preferences.chatLockVerifier = new.isEmpty ? nil : await Self.verifier(new)
        isOpen = false
        return nil
    }

    func close() {
        isOpen = false
        wrongCode = false
    }

    func resetAttempt() {
        wrongCode = false
    }

    @concurrent
    private static func verifies(_ stored: String, _ code: String) async -> Bool {
        chatLockVerifies(stored: stored, code: code)
    }

    @concurrent
    private static func verifier(_ code: String) async -> String? {
        chatLockVerifier(code: code)
    }
}
