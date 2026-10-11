import AppKit
import AVFoundation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A call with pictures: the other side fills the panel, ourselves in a
/// corner, the controls over the bottom, as FaceTime lays it out. Until the
/// other side's video comes, their photo stands in on black.
struct VideoCallContent: View {
    let call: CallInfo
    let model: AppModel

    static let size = CGSize(width: 360, height: 480)

    var body: some View {
        ZStack {
            Color.black
            if call.peerVideo, !model.appLock.isLocked {
                LayerView(layer: model.calls.remoteVideo.layer, quarterTurns: model.calls.remoteOrientation)
            } else {
                VStack(spacing: 10) {
                    CallAvatar(call: call, model: model, size: 84)
                    Text(call.phase == .active ? String(localized: "Camera off") : CallStatus.describe(call))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CallFace.name(call, model: model))
                            .font(.headline)
                            .lineLimit(1)
                        CallStatus(call: call, connectedAt: model.calls.connectedAt)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    Spacer(minLength: 8)
                    if !model.appLock.isLocked, call.camera, let camera = model.calls.camera {
                        CameraPreview(session: camera.session)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding(14)
                Spacer()
                HStack(spacing: 28) {
                    VideoControls(call: call, calls: model.calls)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Mute, the camera and End over the picture.
private struct VideoControls: View {
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
        RoundButton(
            symbol: call.camera ? "video.fill" : "video.slash.fill",
            style: .toggle(on: call.camera),
            label: call.camera ? String(localized: "Camera Off") : String(localized: "Camera")
        ) {
            Task { await calls.toggleCamera() }
        }
        RoundButton(symbol: "phone.down.fill", style: .end, label: String(localized: "End")) {
            calls.hangUp()
        }
        .keyboardShortcut(.cancelAction)
    }
}

/// Shows a layer made elsewhere, turned upright by the sender's rotation.
private struct LayerView: NSViewRepresentable {
    let layer: CALayer
    let quarterTurns: UInt8

    func makeNSView(context: Context) -> LayerHost {
        LayerHost(content: layer)
    }

    func updateNSView(_ view: LayerHost, context: Context) {
        view.quarterTurns = quarterTurns
    }
}

/// Our camera's picture, mirrored as a mirror shows it.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> LayerHost {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        return LayerHost(content: preview)
    }

    func updateNSView(_ view: LayerHost, context: Context) {}
}

/// Keeps one sublayer filling it, rotated by whole quarter turns.
final class LayerHost: NSView {
    private let content: CALayer
    var quarterTurns: UInt8 = 0 {
        didSet { if quarterTurns != oldValue { needsLayout = true } }
    }

    init(content: CALayer) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let turns = CGFloat(quarterTurns % 4)
        let sideways = Int(turns) % 2 == 1
        content.bounds = CGRect(
            x: 0, y: 0,
            width: sideways ? bounds.height : bounds.width,
            height: sideways ? bounds.width : bounds.height
        )
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Clockwise, which is negative in Core Animation's y-up space.
        content.setAffineTransform(CGAffineTransform(rotationAngle: -turns * .pi / 2))
        CATransaction.commit()
    }
}
