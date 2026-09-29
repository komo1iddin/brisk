import AppKit
import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Everything the window shows while the app lock is closed (upstream's
/// `ui/lock.rs`): the password, Touch ID when allowed, and "Forgot
/// password?", which can only unlink.
public struct LockScreen: View {
    private let model: AppModel
    @State private var password = ""
    @State private var confirmingForget = false
    @FocusState private var focused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let lock = model.appLock
        VStack(spacing: Metrics.l) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: Metrics.xs) {
                Text("ZapFast Is Locked").font(.title2.weight(.semibold))
                Text(lock.unlinking ? "Unlinking this Mac…" : "Enter your password to open your chats.")
                    .foregroundStyle(.secondary)
            }

            if !lock.unlinking {
                HStack(spacing: Metrics.s) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .focused($focused)
                        .onSubmit(unlock)
                        .disabled(lock.checking)
                    if lock.canUseTouchID {
                        Button {
                            Task { await lock.unlockWithTouchID(reason: touchIDReason) }
                        } label: {
                            Image(systemName: "touchid").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .help("Unlock with Touch ID")
                        .accessibilityLabel("Unlock with Touch ID")
                    }
                }

                status(lock)
                    .frame(height: 18)

                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(password.isEmpty || lock.checking)

                Button("Forgot Password?") { confirmingForget = true }
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(Metrics.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            focused = true
            if lock.canUseTouchID {
                Task { await lock.unlockWithTouchID(reason: touchIDReason) }
            }
        }
        .onChange(of: lock.wrongPassword) { _, wrong in if wrong { password = "" } }
        .alert("Forgot your password?", isPresented: $confirmingForget) {
            Button("Unlink", role: .destructive) { model.unlinkToForgetPassword() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The only way back in is to unlink this Mac from your phone, which also forgets the password. Messages already copied here stay in the local archive. Link again from your phone afterwards.")
        }
    }

    private var touchIDReason: String {
        String(localized: "open ZapFast")
    }

    @ViewBuilder
    private func status(_ lock: AppLock) -> some View {
        if lock.checking {
            ProgressView().controlSize(.small)
        } else if let retryAt = lock.retryAt, retryAt > .now {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                Text(seconds > 0 ? "Wrong password. Try again in \(seconds) s." : "Wrong password. Try again.")
                    .foregroundStyle(.red)
            }
        } else if lock.wrongPassword {
            Text("Wrong password. Try again.").foregroundStyle(.red)
        }
    }

    private func unlock() {
        let typed = password
        guard !typed.isEmpty else { return }
        Task { await model.appLock.unlock(password: typed) }
    }
}
