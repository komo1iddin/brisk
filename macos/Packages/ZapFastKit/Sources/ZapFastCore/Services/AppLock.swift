import Foundation
import LocalAuthentication
import Observation
import ZapFastBridge

/// The app lock (upstream's `src/app_lock.rs`): a password that hides the
/// whole window at start, after a while without input, or on request. It
/// keeps people using this Mac out of the chats and encrypts nothing; a
/// forgotten password means unlinking.
///
/// Only upstream's salted PBKDF2 verifier is kept, in `Preferences`.
/// Checking or making one takes tens of milliseconds, so it runs off the
/// main actor. Touch ID may open it too, when the person allows it.
@Observable
public final class AppLock {
    public private(set) var isLocked: Bool
    /// A password is being checked.
    public private(set) var checking = false
    /// The last password tried was wrong.
    public private(set) var wrongPassword = false
    /// After repeated wrong passwords, the next try waits until then.
    public private(set) var retryAt: Date?
    /// "Forgot password?" asked to unlink; the lock lifts once WhatsApp
    /// confirms it.
    public private(set) var unlinking = false

    /// Called when the lock closes and when it opens.
    @ObservationIgnored var onLock: () -> Void = {}
    @ObservationIgnored var onUnlock: () -> Void = {}
    @ObservationIgnored var now: () -> Date = { .now }

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var failures: UInt32 = 0
    @ObservationIgnored private var lastInput = Date.now
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    /// Upstream's shortest password, in characters.
    public static let minimumLength = Int(appLockMinPasswordChars())

    init(preferences: Preferences) {
        self.preferences = preferences
        // A set password locks at start.
        isLocked = preferences.appLockVerifier != nil
    }

    public var isEnabled: Bool {
        preferences.appLockVerifier != nil
    }

    /// Touch ID can stand in for the password here.
    public var canUseTouchID: Bool {
        preferences.unlockWithTouchID && Self.touchIDAvailable
    }

    public static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public var canTry: Bool {
        !checking && (retryAt.map { now() >= $0 } ?? true)
    }

    // MARK: Locking

    /// Closes the lock now (the menu command, or the idle timer).
    public func lock() {
        guard isEnabled, !isLocked else { return }
        isLocked = true
        wrongPassword = false
        idleTask?.cancel()
        onLock()
    }

    /// Something was typed or clicked in the app.
    public func noteInput() {
        lastInput = now()
    }

    /// Counts time without input and locks once it passes the chosen
    /// wait, also while ZapFast is in the background.
    func startIdleTimer() {
        idleTask?.cancel()
        guard isEnabled, !isLocked else { return }
        lastInput = now()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let deadline = lastInput.addingTimeInterval(TimeInterval(preferences.appLockAfter.rawValue))
                let left = deadline.timeIntervalSince(now())
                if left <= 0 {
                    lock()
                    return
                }
                try? await Task.sleep(for: .seconds(max(1, left)))
            }
        }
    }

    // MARK: Unlocking

    public func unlock(password: String) async {
        guard isLocked, canTry, let stored = preferences.appLockVerifier, !password.isEmpty else { return }
        checking = true
        let matched = await Self.verifies(stored, password)
        checking = false
        guard isLocked else { return }
        if matched {
            open()
        } else {
            failures += 1
            wrongPassword = true
            let wait = appLockWaitSeconds(failures: failures)
            retryAt = wait > 0 ? now().addingTimeInterval(TimeInterval(wait)) : nil
        }
    }

    public func unlockWithTouchID(reason: String) async {
        guard isLocked, canUseTouchID else { return }
        if await Self.authenticate(reason: reason) { open() }
    }

    /// "Forgot password?": unlinking is how a forgotten one is recovered.
    func startUnlinking() {
        unlinking = true
    }

    /// Unlinking finished: the password is forgotten and the lock lifts.
    func forget() {
        preferences.appLockVerifier = nil
        unlinking = false
        failures = 0
        retryAt = nil
        idleTask?.cancel()
        if isLocked {
            isLocked = false
            onUnlock()
        }
    }

    private func open() {
        failures = 0
        retryAt = nil
        wrongPassword = false
        isLocked = false
        onUnlock()
        startIdleTimer()
    }

    // MARK: Settings

    public enum FormMode: Identifiable, Sendable {
        case set, change, turnOff
        public var id: Self { self }
    }

    public enum FormError: Error, Equatable, Sendable { case tooShort, mismatch, wrongCurrent }

    /// Upstream's `Form::check`, then the slow part: the current password
    /// for a change or turning off, and a verifier for the new one.
    public func submit(_ mode: FormMode, current: String, new: String, confirm: String) async -> FormError? {
        if mode != .turnOff {
            // Upstream counts Unicode scalars (Rust `chars`).
            if new.unicodeScalars.count < Self.minimumLength { return .tooShort }
            if new != confirm { return .mismatch }
        }
        if mode != .set, let stored = preferences.appLockVerifier {
            guard await Self.verifies(stored, current) else { return .wrongCurrent }
        }
        switch mode {
        case .turnOff:
            preferences.appLockVerifier = nil
            idleTask?.cancel()
        case .set, .change:
            preferences.appLockVerifier = await Self.verifier(new)
            startIdleTimer()
        }
        return nil
    }

    // MARK: Off the main actor

    @concurrent
    private static func verifies(_ stored: String, _ password: String) async -> Bool {
        appLockVerifies(stored: stored, password: password)
    }

    @concurrent
    private static func verifier(_ password: String) async -> String {
        appLockVerifier(password: password)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}
