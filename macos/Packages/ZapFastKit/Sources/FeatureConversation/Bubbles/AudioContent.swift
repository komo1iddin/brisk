/// A voice message or an audio file inside a bubble: the player, the
/// sender's avatar on it, and the waveform it draws.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

struct AudioContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let seconds: UInt32?
    let voiceNote: Bool
    let waveform: Data
    let model: AppModel
    let footer: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let waveWidth: CGFloat = 170
    private static let sideWidth: CGFloat = 40

    /// The play button, the waveform with the duration and time under it,
    /// and at the end the recorder's photo, which the speed control takes
    /// over while the message plays, as on the phone.
    var body: some View {
        let key = MessageKey(chat: message.chat, message: message.id)
        let player = model.voice
        let current = player.isCurrent(key)
        let downloading = model.conversations.download(key) == .downloading
        let showsAvatar = voiceNote && model.preferences.voiceAvatars
        let showsSpeed = current && voiceNote
        HStack(spacing: Metrics.s) {
            Button { model.playAudio(message) } label: {
                Group {
                    if downloading || player.preparing == key {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol(current: current, playing: player.isPlaying))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 30))
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(current: current, playing: player.isPlaying))

            VStack(alignment: .leading, spacing: 2) {
                WaveformView(samples: Array(waveform), progress: player.progress(of: key)) { fraction in
                    model.seekAudio(message, to: fraction)
                }
                .frame(width: Self.waveWidth, height: 26)

                HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
                    Text(timeLabel(current: current))
                        .font(.caption.monospacedDigit())
                        .opacity(0.8)
                    Spacer(minLength: 0)
                    footer
                }
                .frame(width: Self.waveWidth)
            }
            .padding(.top, Metrics.xs)

            if showsSpeed || showsAvatar {
                ZStack {
                    if showsSpeed {
                        Button { model.cycleVoiceSpeed() } label: {
                            Text(speedLabel)
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .frame(width: Self.sideWidth, height: 26)
                                .background(.quaternary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Playback speed")
                        .accessibilityLabel("Playback speed")
                        .accessibilityValue(Text(verbatim: speedLabel))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        RecorderAvatar(message: message, model: model)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .frame(width: Self.sideWidth, height: Self.sideWidth)
                .animation(.zf(reduceMotion), value: showsSpeed)
            }
        }
        .task(id: message.id) { model.autoDownload(message) }
    }

    private func symbol(current: Bool, playing: Bool) -> String {
        if media.path == nil { return "arrow.down.circle.fill" }
        return current && playing ? "pause.circle.fill" : "play.circle.fill"
    }

    private func label(current: Bool, playing: Bool) -> Text {
        if media.path == nil { return Text("Download") }
        return current && playing ? Text("Pause") : Text("Play")
    }

    private func timeLabel(current: Bool) -> String {
        let total = seconds.map(TimeInterval.init) ?? model.voice.duration
        let shown = current && model.voice.position > 0 ? model.voice.position : total
        return Duration.seconds(Int(shown.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }

    private var speedLabel: String {
        let speed = model.preferences.voiceSpeed
        return speed == 1 ? "1×" : speed == 2 ? "2×" : "1.5×"
    }
}

/// Who recorded a voice message, with a microphone on the photo as on the
/// phone: blue once ours was played, the accent colour on theirs.
struct RecorderAvatar: View {
    let message: MessageRecord
    let model: AppModel
    @Environment(\.chatTheme) private var theme

    var body: some View {
        let id = message.fromMe ? model.session.account?.id ?? message.sender : message.sender
        let name = message.fromMe
            ? model.session.account?.name ?? ""
            : model.chats.personName(message.sender, hint: message.senderName)
        AvatarView(
            url: model.avatars.url(for: id),
            seed: id,
            placeholder: .initials(String(name.trimmingPrefix("~"))),
            size: 40,
            version: model.avatars.version(for: id)
        )
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(micColor)
                .shadow(color: .black.opacity(0.35), radius: 1)
                .offset(x: 1, y: 2)
        }
        .accessibilityHidden(true)
    }

    private var micColor: Color {
        if message.fromMe { return message.status == .played ? theme.readTicks : theme.outgoingText.opacity(0.8) }
        return theme.accent
    }
}

/// The sender's 64-bar waveform; bars before `progress` are drawn solid.
/// Clicking or dragging seeks.
struct WaveformView: View {
    let samples: [UInt8]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let bars = samples.isEmpty ? Array(repeating: UInt8(20), count: 40) : samples
                let step = size.width / CGFloat(bars.count)
                for (index, sample) in bars.enumerated() {
                    let height = max(2, size.height * CGFloat(sample) / 100)
                    let rect = CGRect(
                        x: CGFloat(index) * step,
                        y: (size.height - height) / 2,
                        width: max(1.5, step * 0.55),
                        height: height
                    )
                    let played = (CGFloat(index) + 0.5) / CGFloat(bars.count) <= progress
                    var bar = context
                    bar.opacity = played ? 1 : 0.4
                    bar.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                seek(Double(value.location.x / max(1, proxy.size.width)))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Voice message")
        .accessibilityValue(Text("\(Int(progress * 100)) percent played"))
        // VoiceOver and the keyboard move through it a tenth at a time.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(1, progress + 0.1))
            case .decrement: seek(max(0, progress - 0.1))
            @unknown default: break
            }
        }
    }
}
