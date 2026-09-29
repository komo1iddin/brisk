import SwiftUI
import ZapFastCore
import ZapFastDesign

/// The app lock: turn it on with a password, change or turn it off (the
/// current password first), when it closes, and Touch ID.
struct PrivacySettings: View {
    let model: AppModel
    @State private var form: AppLock.FormMode?

    var body: some View {
        @Bindable var preferences = model.preferences
        let lock = model.appLock
        Form {
            Section {
                LabeledContent("App lock") {
                    if lock.isEnabled {
                        Button("Change Password…") { form = .change }
                        Button("Turn Off…") { form = .turnOff }
                    } else {
                        Button("Set Password…") { form = .set }
                    }
                }
                if lock.isEnabled {
                    Picker("Lock after", selection: $preferences.appLockAfter) {
                        Text("1 minute").tag(AutoLock.oneMinute)
                        Text("15 minutes").tag(AutoLock.fifteenMinutes)
                        Text("1 hour").tag(AutoLock.oneHour)
                    }
                    if AppLock.touchIDAvailable {
                        Toggle("Unlock with Touch ID", isOn: $preferences.unlockWithTouchID)
                    }
                }
            } footer: {
                Text(lock.isEnabled
                    ? "Time without using ZapFast, also counted while it is in the background. Lock ZapFast (⌃⌘L) locks it at once."
                    : "Asks for a password at start and after a while unused. It keeps people using this Mac out of your chats and encrypts nothing more. A forgotten password means unlinking.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.appLockAfter) { model.appLock.noteInput() }
        .sheet(item: $form) { mode in
            PasswordForm(mode: mode, lock: lock)
        }
    }
}

/// Upstream's password form: the current password for a change or turning
/// off, and a new one typed twice.
private struct PasswordForm: View {
    let mode: AppLock.FormMode
    let lock: AppLock
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: AppLock.FormError?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text(title).font(.headline)
            Form {
                if mode != .set {
                    SecureField("Current password", text: $current)
                }
                if mode != .turnOff {
                    SecureField("New password", text: $new)
                    SecureField("Confirm password", text: $confirm)
                }
            }
            .formStyle(.columns)
            if let error {
                Text(message(error)).foregroundStyle(.red).font(.callout)
            } else if mode != .turnOff {
                Text("At least \(AppLock.minimumLength) characters.").foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) { Text(action) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (mode != .set && current.isEmpty) || (mode != .turnOff && new.isEmpty))
            }
        }
        .padding(Metrics.l)
        .frame(width: 360)
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .set: "Set App Lock Password"
        case .change: "Change App Lock Password"
        case .turnOff: "Turn Off App Lock"
        }
    }

    private var action: LocalizedStringKey {
        switch mode {
        case .set: "Turn On"
        case .change: "Change"
        case .turnOff: "Turn Off"
        }
    }

    private func message(_ error: AppLock.FormError) -> LocalizedStringKey {
        switch error {
        case .tooShort: "Use at least \(AppLock.minimumLength) characters."
        case .mismatch: "The passwords don't match."
        case .wrongCurrent: "The current password is wrong."
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            let problem = await lock.submit(mode, current: current, new: new, confirm: confirm)
            busy = false
            if let problem {
                error = problem
                if problem == .wrongCurrent { current = "" }
            } else {
                dismiss()
            }
        }
    }
}
