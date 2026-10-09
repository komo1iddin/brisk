import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Privacy in two tabs of the system's own tab view, as Transmission splits
/// its tall panes: what the account shows everyone, kept on the phone, and
/// what this Mac does: receipts, typing, the app lock (turn it on with a
/// password, change or turn it off with the current one first, when it
/// closes, and Touch ID) and the Locked Chats code. As one grouped form it
/// was taller than most screens.
///
/// Inside the tab view's box the rows are a columns form, labels to the
/// left of their controls, as preference panes inside a box are laid out.
struct PrivacySettings: View {
    let model: AppModel
    @AppStorage("privacySettingsPage") private var page: Page = .personalInfo
    @State private var form: AppLock.FormMode?
    @State private var codeForm: CodeFormMode?

    enum Page: String {
        case personalInfo, thisMac
    }


    var body: some View {
        TabView(selection: $page) {
            Tab(value: Page.personalInfo) {
                AccountPrivacyForm(model: model)
                    .settingsBox()
            } label: {
                Text("Personal Info")
            }
            Tab(value: Page.thisMac) {
                thisMac
                    .settingsBox()
            } label: {
                Text("This Mac")
            }
        }
        .tabViewStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Metrics.l)
        .padding(.top, Metrics.m)
        .padding(.bottom, Metrics.l)
        .sheet(item: $form) { mode in
            PasswordForm(mode: mode, lock: model.appLock)
        }
        .sheet(item: $codeForm) { mode in
            ChatLockCodeForm(mode: mode, lockedChats: model.lockedChats)
        }
    }

    private var thisMac: some View {
        @Bindable var preferences = model.preferences
        @Bindable var accountPreferences = model.accountPreferences
        let lock = model.appLock
        return Form {
            Section {
                LabeledContent("Receipts:") {
                    VStack(alignment: .leading, spacing: Metrics.s) {
                        Toggle("Send read receipts", isOn: $accountPreferences.sendReadReceipts)
                        Toggle("Show when you are typing", isOn: $accountPreferences.sendTyping)
                    }
                }
                Text(model.session.receiptsDisabled
                    ? "Read receipts are off for your account, so only groups get them."
                    : "With read receipts off, people don't see blue ticks or played voice messages from this Mac.")
                    .settingsCaption(endsGroup: true)
            }
            Section {
                LabeledContent("App lock:") {
                    HStack {
                        if lock.isEnabled {
                            Button("Change Password…") { form = .change }
                            Button("Turn Off…") { form = .turnOff }
                        } else {
                            Button("Set Password…") { form = .set }
                        }
                    }
                }
                if lock.isEnabled {
                    LabeledContent("Lock after:") {
                        Picker("Lock after:", selection: $preferences.appLockAfter) {
                            Text("1 minute").tag(AutoLock.oneMinute)
                            Text("15 minutes").tag(AutoLock.fifteenMinutes)
                            Text("1 hour").tag(AutoLock.oneHour)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if AppLock.touchIDAvailable {
                        Toggle("Unlock with Touch ID", isOn: $preferences.unlockWithTouchID)
                    }
                }
                Text(lock.isEnabled
                    ? "Time without using ZapFast, also counted while it is in the background. Lock ZapFast (⌃⌘L) locks it at once."
                    : "Asks for a password at start and after a while unused. It keeps people using this Mac out of your chats and encrypts nothing more. A forgotten password means unlinking.")
                    .settingsCaption(endsGroup: true)
            }
            Section {
                LabeledContent("Locked chats:") {
                    HStack {
                        if model.lockedChats.hasCode {
                            Button("Change Code…") { codeForm = .change }
                            Button("Remove Code…") { codeForm = .remove }
                        } else {
                            Button("Set Code…") { codeForm = .set }
                        }
                    }
                }
                Text("The code opens Locked Chats on this Mac. It hides chats; it doesn't encrypt them.")
                    .settingsCaption()
            }
        }
        .onChange(of: preferences.appLockAfter) { model.appLock.noteInput() }
    }
}

private extension View {
    /// A columns form inside the tab view's box, with the box's margins.
    func settingsBox() -> some View {
        formStyle(.columns)
            .padding(.horizontal, Metrics.xl)
            .padding(.vertical, Metrics.xl)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The small grey print under a control, in the small system size
    /// preference panes use for it. One that closes a group of controls
    /// leaves a gap before the next group, as the groups of a pane are
    /// set apart by space rather than lines.
    func settingsCaption(endsGroup: Bool = false) -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, endsGroup ? Metrics.l : Metrics.xs)
    }
}

/// Who sees what of the account. The values live on the phone: they are
/// read each time Settings shows and written one at a time.
private struct AccountPrivacyForm: View {
    let model: AppModel

    var body: some View {
        let privacy = model.privacy
        let writable = privacy.isEditable && model.session.isConnected
        Form {
            Section {
                ForEach(privacy.kinds, id: \.self) { kind in
                    LabeledContent(label(kind)) {
                        Picker(selection: binding(kind)) {
                            if privacy.choice(kind) == nil {
                                Text(verbatim: "—").tag(PrivacyChoiceInfo?.none)
                            }
                            ForEach(privacy.choices(kind), id: \.self) { choice in
                                Text(label(choice))
                                    .tag(Optional(choice))
                                    .selectionDisabled(!privacyChoices(kind: kind).contains(choice))
                            }
                        } label: {
                            Text(label(kind))
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!writable || privacy.isPending(kind))
                        if privacy.isPending(kind) { ProgressView().controlSize(.mini) }
                    }
                    if let hint = hint(kind) {
                        Text(hint).settingsCaption()
                    }
                }
            }
            Text(footer(privacy))
                .settingsCaption()
                .padding(.top, Metrics.m)
        }
        .onAppear { model.refreshPrivacy() }
    }

    private func binding(_ kind: PrivacyKindInfo) -> Binding<PrivacyChoiceInfo?> {
        Binding(
            get: { model.privacy.choice(kind) },
            set: { if let choice = $0 { model.setPrivacy(kind, to: choice) } }
        )
    }

    private func footer(_ privacy: PrivacyStore) -> LocalizedStringKey {
        if !model.session.isConnected { return "Connect to WhatsApp to see and change these." }
        if privacy.fetchFailed { return "Your phone didn't answer; these may be out of date." }
        if !privacy.isEditable { return "Asking your phone…" }
        return "Kept on your phone and used on every linked device. People excepted from “My contacts” are edited on the phone."
    }

    private func label(_ kind: PrivacyKindInfo) -> LocalizedStringKey {
        switch kind {
        case .lastSeen: "Last seen:"
        case .online: "Online:"
        case .profile: "Profile photo:"
        case .about: "About:"
        case .groupAdd: "Groups:"
        case .readReceipts: "Read receipts:"
        case .callAdd: "Calls:"
        }
    }

    private func hint(_ kind: PrivacyKindInfo) -> LocalizedStringKey? {
        switch kind {
        case .groupAdd: "Who can add you to groups."
        case .readReceipts: "For your whole account. Groups always send them."
        default: nil
        }
    }

    private func label(_ choice: PrivacyChoiceInfo) -> LocalizedStringKey {
        switch choice {
        case .everyone: "Everyone"
        case .contacts: "My contacts"
        case .except: "My contacts except…"
        case .nobody: "Nobody"
        case .sameAsLastSeen: "Same as last seen"
        case .known: "Silence unknown callers"
        }
    }
}

enum CodeFormMode: Identifiable {
    case set, change, remove
    var id: Self { self }
}

/// Sets, replaces or removes the local code of Locked Chats; the current
/// code first when there is one. Changing it locks the folder again.
private struct ChatLockCodeForm: View {
    let mode: CodeFormMode
    let lockedChats: LockedChats
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: LockedChats.CodeError?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text(title).font(.headline)
            Form {
                if mode != .set {
                    SecureField("Current code", text: $current)
                }
                if mode != .remove {
                    SecureField("New code", text: $new)
                    SecureField("Confirm code", text: $confirm)
                }
            }
            .formStyle(.columns)
            if let error {
                Text(message(error)).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .remove ? "Remove" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (mode != .set && current.isEmpty) || (mode != .remove && new.isEmpty))
            }
        }
        .padding(Metrics.l)
        .frame(width: 360)
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .set: "Set Locked Chats Code"
        case .change: "Change Locked Chats Code"
        case .remove: "Remove Locked Chats Code"
        }
    }

    private func message(_ error: LockedChats.CodeError) -> LocalizedStringKey {
        switch error {
        case .wrongCurrent: "The current code is wrong."
        case .mismatch: "The codes don't match."
        case .empty: "Enter a code."
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            let problem = await lockedChats.change(
                current: current, new: mode == .remove ? "" : new, confirm: mode == .remove ? "" : confirm
            )
            busy = false
            if let problem { error = problem } else { dismiss() }
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
