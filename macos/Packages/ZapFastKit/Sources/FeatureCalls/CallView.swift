import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The call window's content: who, where the call stands, and the buttons
/// for it. While the app lock is closed it says only that a call came, as
/// notifications say only "New message".
struct CallView: View {
    let model: AppModel

    var body: some View {
        if let call = model.calls.call {
            VStack(spacing: 0) {
                if let waiting = model.calls.waiting {
                    WaitingBanner(call: waiting, model: model)
                    Divider()
                }
                CallContent(call: call, model: model)
            }
        }
    }
}

/// A second call ringing during this one: decline it, or end this call and
/// take it. WhatsApp has no hold.
private struct WaitingBanner: View {
    let call: CallInfo
    let model: AppModel

    private var hidden: Bool { model.appLock.isLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if hidden {
                    AvatarView(url: nil, seed: "call", placeholder: .symbol("phone.fill"), size: 32)
                } else {
                    AvatarView(
                        url: model.avatars.url(for: call.chat),
                        seed: call.chat,
                        placeholder: .initials(model.chats.displayName(call.chat)),
                        size: 32,
                        version: model.avatars.version(for: call.chat)
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(hidden ? String(localized: "WhatsApp Call") : model.chats.displayName(call.chat))
                        .font(.headline)
                        .lineLimit(1)
                    Text(String(localized: "Calling you"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Decline")) { model.calls.declineWaiting() }
                    .buttonStyle(CapsuleFill(color: .red))
                Button(String(localized: "End & Accept")) {
                    Task { await model.calls.answerWaiting() }
                }
                .buttonStyle(CapsuleFill(color: .green))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 280)
    }
}

private struct CallContent: View {
    let call: CallInfo
    let model: AppModel

    private var hidden: Bool { model.appLock.isLocked }

    var body: some View {
        VStack(spacing: 14) {
            avatar
            VStack(spacing: 4) {
                Text(hidden ? String(localized: "WhatsApp Call") : model.chats.displayName(call.chat))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                CallStatus(call: call, connectedAt: model.calls.connectedAt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            CallButtons(call: call, calls: model.calls)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 280)
    }

    @ViewBuilder private var avatar: some View {
        if hidden {
            AvatarView(url: nil, seed: "call", placeholder: .symbol("phone.fill"), size: 72)
        } else {
            AvatarView(
                url: model.avatars.url(for: call.chat),
                seed: call.chat,
                placeholder: .initials(model.chats.displayName(call.chat)),
                size: 72,
                version: model.avatars.version(for: call.chat)
            )
        }
    }
}

/// A filled capsule in a call's own colour. The panel never becomes the key
/// window, where system prominent buttons would turn grey.
private struct CapsuleFill: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

/// "Calling…", the time talked, or why it ended.
private struct CallStatus: View {
    let call: CallInfo
    let connectedAt: Date?

    var body: some View {
        switch call.phase {
        case .active:
            if let connectedAt {
                TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                    Text(Self.duration(context.date.timeIntervalSince(connectedAt)))
                        .monospacedDigit()
                }
            }
        default:
            Text(Self.describe(call))
        }
    }

    static func describe(_ call: CallInfo) -> String {
        switch call.phase {
        case .ringing:
            call.videoOffered
                ? String(localized: "Video call · answer with voice only")
                : String(localized: "Incoming voice call")
        case .calling: String(localized: "Calling…")
        case .connecting: String(localized: "Connecting…")
        case .active: ""
        case .ended(let reason): ended(reason)
        }
    }

    static func ended(_ reason: CallEndReason) -> String {
        switch reason {
        case .hungUp, .peerHungUp: String(localized: "Call ended")
        case .declined: String(localized: "Declined")
        case .peerDeclined: String(localized: "Declined")
        case .missed: String(localized: "Missed call")
        case .noAnswer: String(localized: "No answer")
        case .answeredElsewhere: String(localized: "Answered on another device")
        case .declinedElsewhere: String(localized: "Declined on another device")
        case .connectionLost: String(localized: "Connection lost")
        case .failed: String(localized: "Call failed")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

private struct CallButtons: View {
    let call: CallInfo
    let calls: CallStore

    var body: some View {
        HStack(spacing: 28) {
            switch call.phase {
            case .ringing:
                RoundButton(symbol: "phone.down.fill", style: .end, label: String(localized: "Decline")) {
                    calls.hangUp()
                }
                .keyboardShortcut(.cancelAction)
                RoundButton(symbol: "phone.fill", style: .accept, label: String(localized: "Accept")) {
                    Task { await calls.answer() }
                }
                .keyboardShortcut(.defaultAction)
            case .calling, .connecting, .active:
                RoundButton(
                    symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                    style: .toggle(on: call.muted),
                    label: call.muted ? String(localized: "Unmute") : String(localized: "Mute")
                ) {
                    calls.toggleMute()
                }
                RoundButton(symbol: "phone.down.fill", style: .end, label: String(localized: "End")) {
                    calls.hangUp()
                }
                .keyboardShortcut(.cancelAction)
            case .ended:
                EmptyView()
            }
        }
        .frame(minHeight: 72)
    }
}

/// A round button with its name under it, as the phone's call screen has.
private struct RoundButton: View {
    enum Style {
        case accept, end
        /// A setting such as mute, filled while on.
        case toggle(on: Bool)
    }

    let symbol: String
    let style: Style
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(background))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        switch style {
        case .accept, .end: .white
        case .toggle(let on): on ? Color(nsColor: .windowBackgroundColor) : .primary
        }
    }

    private var background: Color {
        switch style {
        case .accept: .green
        case .end: .red
        case .toggle(let on): on ? .primary : .primary.opacity(0.1)
        }
    }
}
