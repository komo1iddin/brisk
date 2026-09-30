import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Shown until this Mac is linked: the QR code, pairing by phone number,
/// and the connection's other states.
public struct LinkingView: View {
    private let model: AppModel

    @State private var method: Method = .qr
    @State private var phone = ""
    @State private var confirmStartOver = false

    private enum Method { case qr, phone }

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Metrics.xl) {
                header
                content
                    .frame(maxWidth: 420)
            }
            .padding(Metrics.xl * 2)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.background)
        .confirmationDialog(
            "Start over with a new archive?",
            isPresented: $confirmStartOver
        ) {
            Button("Start Over", role: .destructive) { model.startOverArchive() }
        } message: {
            Text("The unreadable archive is set aside, not deleted, and this Mac links again from scratch.")
        }
    }

    private var header: some View {
        VStack(spacing: Metrics.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Link ZapFast with your phone")
                .font(.largeTitle.weight(.semibold))
            Text("Your messages stay end-to-end encrypted. History is copied to this Mac once, after linking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.session.link {
        case .starting, .connecting:
            ProgressRow(text: String(localized: "Connecting…"))
        case let .unlinked(qr, pairCode, _):
            if let pairCode {
                PairCodeCard(code: pairCode) { method = .qr; model.reconnect() }
            } else if method == .phone {
                phoneForm
            } else {
                qrCard(qr)
            }
        case .connected:
            ProgressRow(text: String(localized: "Linked. Copying recent history…"))
        case .disconnected(let reason):
            StatusCard(
                symbol: "wifi.slash",
                title: String(localized: "Connection lost"),
                detail: reason,
                action: (String(localized: "Try Again"), model.reconnect)
            )
        case .loggedOut:
            StatusCard(
                symbol: "iphone",
                title: String(localized: "This Mac was unlinked"),
                detail: String(localized: "Link it again to keep using ZapFast."),
                action: (String(localized: "Link Again"), model.reconnect)
            )
        case .failed(let message):
            VStack(spacing: Metrics.m) {
                StatusCard(
                    symbol: "exclamationmark.circle.fill",
                    title: String(localized: "ZapFast could not start"),
                    detail: message,
                    action: (String(localized: "Try Again"), model.reconnect)
                )
                Button("Start Over…", role: .destructive) { confirmStartOver = true }
                    .buttonStyle(.link)
            }
        }
    }

    private func qrCard(_ qr: String?) -> some View {
        VStack(spacing: Metrics.l) {
            Group {
                if let qr {
                    QRCodeView(payload: qr)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 264, height: 264)

            VStack(alignment: .leading, spacing: Metrics.s) {
                Step(number: 1, text: String(localized: "Open WhatsApp on your phone"))
                Step(number: 2, text: String(localized: "Go to Settings › Linked Devices › Link a Device"))
                Step(number: 3, text: String(localized: "Point your phone at this screen"))
            }

            Button("Link with phone number instead") { method = .phone }
                .buttonStyle(.link)
        }
        .padding(Metrics.xl)
        .modifier(GlassCard())
    }

    private var phoneForm: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Enter your phone number with its country code.")
                .foregroundStyle(.secondary)
            TextField("Phone number", text: $phone, prompt: Text("Country code and number"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.telephoneNumber)
                .onSubmit(submitPhone)
            HStack {
                Button("Use QR Code") { method = .qr }
                Spacer()
                Button("Next", action: submitPhone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phone.filter(\.isNumber).count < 7)
            }
        }
        .padding(Metrics.xl)
        .modifier(GlassCard())
    }

    private func submitPhone() {
        guard phone.filter(\.isNumber).count >= 7 else { return }
        model.pair(phone: phone)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(.quaternary))
            Text(text)
        }
    }
}

private struct PairCodeCard: View {
    let code: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Metrics.l) {
            Text("Enter this code on your phone")
                .font(.headline)
            Text(Self.grouped(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                // Read letter by letter, as it is typed on the phone.
                .speechSpellsOutCharacters()
            Text("WhatsApp › Settings › Linked Devices › Link a Device › Link with phone number instead")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
        }
        .padding(Metrics.xl)
        .modifier(GlassCard())
    }

    /// "ABCD-EFGH", the way the phone asks for it.
    static func grouped(_ code: String) -> String {
        guard code.count == 8, !code.contains("-") else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Metrics.s) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(Metrics.xl)
    }
}

private struct StatusCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: (String, () -> Void)

    var body: some View {
        VStack(spacing: Metrics.m) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button(action.0, action: action.1)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.xl)
        .frame(maxWidth: .infinity)
        .modifier(GlassCard())
    }
}
