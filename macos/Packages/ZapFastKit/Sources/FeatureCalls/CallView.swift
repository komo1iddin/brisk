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
                if call.showsVideo(locked: model.appLock.isLocked) {
                    VideoCallContent(call: call, model: model)
                } else {
                    CallContent(call: call, model: model)
                }
            }
        }
    }
}

/// A second call ringing during this one: decline it, or end this call and
/// take it. WhatsApp has no hold.
private struct WaitingBanner: View {
    let call: CallInfo
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CallAvatar(call: call, model: model, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CallFace.name(call, model: model))
                        .font(.headline)
                        .lineLimit(1)
                    Text(CallFace.caller(call, model: model) ?? String(localized: "Calling you"))
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

extension CallInfo {
    /// The window shows pictures rather than the caller's photo.
    func showsVideo(locked: Bool) -> Bool {
        guard !locked else { return false }
        return switch phase {
        case .calling, .connecting, .active: camera || peerVideo
        case .ringing, .ended: false
        }
    }
}

private struct CallContent: View {
    let call: CallInfo
    let model: AppModel
    /// The other side's request to switch to video, put aside for now.
    @State private var setAside = false

    var body: some View {
        VStack(spacing: 14) {
            CallAvatar(call: call, model: model, size: 72)
            VStack(spacing: 4) {
                Text(CallFace.name(call, model: model))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if call.phase == .ringing, let caller = CallFace.caller(call, model: model) {
                    Text(caller)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    CallStatus(call: call, connectedAt: model.calls.connectedAt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if call.phase != .ringing, let members = CallFace.participants(call, model: model) {
                    Text(members)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            if call.videoRequested, !setAside, !model.appLock.isLocked {
                VStack(spacing: 8) {
                    Text(String(localized: "Asks to switch to video"))
                        .font(.callout)
                    HStack(spacing: 8) {
                        Button(String(localized: "Not Now")) { setAside = true }
                            .buttonStyle(CapsuleFill(color: .gray))
                        Button(String(localized: "Switch")) {
                            Task { await model.calls.toggleCamera() }
                        }
                        .buttonStyle(CapsuleFill(color: .green))
                    }
                }
            }
            CallButtons(call: call, calls: model.calls)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 280)
    }
}

/// A filled capsule in a call's own colour. The panel never becomes the key
/// window, where system prominent buttons would turn grey.
struct CapsuleFill: ButtonStyle {
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
struct CallStatus: View {
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
            call.group
                ? String(localized: "Group voice call")
                : call.videoOffered ? String(localized: "Incoming video call") : String(localized: "Incoming voice call")
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

    /// How long the call went, once it has ended.
    private var talked: TimeInterval? {
        guard let start = calls.connectedAt else { return nil }
        return (calls.endedAt ?? .now).timeIntervalSince(start)
    }

    var body: some View {
        HStack(spacing: 28) {
            switch call.phase {
            case .ringing:
                RoundButton(symbol: "phone.down.fill", style: .end, label: String(localized: "Decline")) {
                    calls.hangUp()
                }
                .keyboardShortcut(.cancelAction)
                if call.videoOffered, !call.group, !calls.isLocked {
                    RoundButton(symbol: "phone.fill", style: .accept, label: String(localized: "Voice")) {
                        Task { await calls.answer() }
                    }
                    RoundButton(symbol: "video.fill", style: .accept, label: String(localized: "Video")) {
                        Task { await calls.answer(video: true) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    RoundButton(symbol: "phone.fill", style: .accept, label: String(localized: "Accept")) {
                        Task { await calls.answer() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .calling, .connecting, .active:
                InCallButtons(call: call, calls: calls)
            case .ended:
                EndedMark(talked: talked)
            }
        }
        .frame(minHeight: 72)
    }
}

/// Where the buttons were, once the call is over: the hung-up phone, greyed,
/// and how long the call went.
private struct EndedMark: View {
    let talked: TimeInterval?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.secondary.opacity(0.5)))
            Text(talked.map(CallStatus.duration) ?? String(localized: "Ended"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// Mute, the camera and End, during a call.
private struct InCallButtons: View {
    let call: CallInfo
    let calls: CallStore

    var body: some View {
        RoundButton(
            symbol: call.muted ? "mic.slash.fill" : "mic.fill",
            style: .toggle(on: call.muted),
            label: call.muted ? String(localized: "Unmute") : String(localized: "Mute")
        ) {
            calls.toggleMute()
        }
        if !call.group, !calls.isLocked {
            RoundButton(
                symbol: call.camera ? "video.fill" : "video.slash.fill",
                style: .toggle(on: call.camera),
                label: call.camera ? String(localized: "Camera Off") : String(localized: "Camera")
            ) {
                Task { await calls.toggleCamera() }
            }
        }
        RoundButton(symbol: "phone.down.fill", style: .end, label: String(localized: "End")) {
            calls.hangUp()
        }
        .keyboardShortcut(.cancelAction)
    }
}

/// A round button with its name under it, as the phone's call screen has.
struct RoundButton: View {
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
