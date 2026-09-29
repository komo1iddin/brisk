import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The Settings window. A grouped `Form` is the platform's own shape for
/// preferences, so it stays one.
public struct SettingsView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") {
                AccountSettings(model: model)
            }
            Tab("Advanced", systemImage: "gearshape") {
                AdvancedSettings(model: model)
            }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct AccountSettings: View {
    let model: AppModel
    @State private var confirmUnlink = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: model.session.account?.name ?? "—")
                LabeledContent("Phone", value: model.session.account.flatMap { phoneOf(id: $0.id) } ?? "—")
                LabeledContent("Status", value: status)
            }
            Section {
                Button("Unlink This Mac…", role: .destructive) { confirmUnlink = true }
                    .disabled(!model.isLinked)
            } footer: {
                Text("Unlinking removes this Mac from your phone's linked devices. Messages already copied here stay in the local archive.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Unlink this Mac?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) { model.unlink() }
        }
    }

    private var status: String {
        switch model.session.link {
        case .connected: String(localized: "Connected")
        case .connecting, .starting: String(localized: "Connecting")
        case .disconnected: String(localized: "Offline, reconnecting")
        case .unlinked: String(localized: "Not linked")
        case .loggedOut: String(localized: "Unlinked by the phone")
        case .failed: String(localized: "Failed")
        }
    }
}

private struct AdvancedSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Log file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.logFile])
                    }
                }
            } footer: {
                Text("The log never contains message text, phone numbers, or keys. Attach it to bug reports.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
