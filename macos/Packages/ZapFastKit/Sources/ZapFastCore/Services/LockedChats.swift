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
    /// The chat list's search holds the code (upstream's search-code entry,
    /// kept beside the Locked folder): the search shows the folder alone.
    public private(set) var revealedBySearch = false
    @ObservationIgnored private var searchCheck: Task<Void, Never>?

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

    /// Checks what the chat list's search holds against the code, after a
    /// pause in the typing: the check is slow on purpose.
    public func searchChanged(_ query: String) {
        searchCheck?.cancel()
        revealedBySearch = false
        let code = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored = preferences.chatLockVerifier, !code.isEmpty, !isOpen else { return }
        searchCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let matched = await Self.verifies(stored, code)
            guard !Task.isCancelled, let self else { return }
            self.revealedBySearch = matched
        }
    }

    /// Opens the folder the search revealed.
    public func openRevealed() {
        guard revealedBySearch else { return }
        revealedBySearch = false
        wrongCode = false
        isOpen = true
    }

    func close() {
        isOpen = false
        wrongCode = false
        revealedBySearch = false
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
