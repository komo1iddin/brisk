import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Opens Locked Chats with the local code, or sets that code up the first
/// time (upstream's "Set up locked chats"). Touch ID may stand in once a
/// code exists.
struct LockedChatsSheet: View {
    let model: AppModel
    @State private var code = ""
    @State private var confirm = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let locked = model.lockedChats
        let setup = !locked.hasCode
        VStack(alignment: .leading, spacing: Metrics.m) {
            Label(setup ? "Set Up Locked Chats" : "Locked Chats", systemImage: "lock.fill")
                .font(.headline)
            Text(setup
                ? "Choose a local code to open Locked Chats. It is separate from your phone's code. This hides chats in ZapFast; it doesn't add another layer of encryption."
                : "Enter your local ZapFast code. Going back or closing the window locks them again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                SecureField("Local code", text: $code)
                if setup {
                    SecureField("Confirm code", text: $confirm)
                }
            }
            .formStyle(.columns)
            .onSubmit(submit)
            if locked.wrongCode {
                Text("That code didn't match. Try again.").foregroundStyle(.red).font(.callout)
            } else if setup, !confirm.isEmpty, trimmed(code) != trimmed(confirm) {
                Text("The codes don't match.").foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                if locked.canUseTouchID {
                    Button("Use Touch ID", systemImage: "touchid") {
                        Task {
                            await locked.openWithTouchID(reason: String(localized: "open your locked chats"))
                            if locked.isOpen { model.lockedChatsOpened() }
                        }
                    }
                }
                if locked.checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(setup ? "Set Code and Open" : "Open", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || locked.checking)
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }

    private var ready: Bool {
        !trimmed(code).isEmpty && (model.lockedChats.hasCode || trimmed(code) == trimmed(confirm))
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard ready else { return }
        let typed = code
        let locked = model.lockedChats
        Task {
            if locked.hasCode {
                if await locked.open(code: typed) { model.lockedChatsOpened() } else { code = "" }
            } else {
                await locked.setUp(code: typed)
                if locked.isOpen { model.lockedChatsOpened() }
            }
        }
    }
}
