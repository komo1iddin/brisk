import AVFoundation
import Foundation
import OSLog
import Synchronization

/// The Mac's camera during a call: 720p (or what the camera has) at the
/// call's frame rate, handed to the encoder, with a preview of ourselves.
nonisolated public final class CallCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ZapFast.CallCamera")
    private let frameRate: Int
    private let send: @Sendable (Data, UInt32) -> Void
    private let log = Logger(subsystem: "ZapFast", category: "Calls")
    private let capture: CallCaptureGate
    private let failed: @Sendable () -> Void
    private let configure: @Sendable (AVCaptureSession) -> Bool
    private let failureReported = Atomic<Bool>(false)
    private let keyframeRequested = Atomic<Bool>(true)
    // Touched only on `queue`.
    private var encoder: VideoEncoder?
    private var lastFrame: CMTime = .invalid
    private var observers: [NSObjectProtocol] = []

    init(frameRate: Int, send: @escaping @Sendable (Data, UInt32) -> Void,
         onFailure: @escaping @Sendable () -> Void = {},
         configure: @escaping @Sendable (AVCaptureSession) -> Bool = CallCamera.configureSession) {
        self.frameRate = max(1, frameRate)
        let capture = CallCaptureGate()
        self.capture = capture
        self.send = { data, timestamp in
            capture.forward { send(data, timestamp) }
        }
        failed = onFailure
        self.configure = configure
        super.init()
    }

    /// Asks for the camera if needed. Returns whether it may be used.
    static func allowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Starts capturing on the camera's own queue, as stopping does, so a
    /// quick off and on stay in order. Success means capture actually started.
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard capture.isOpen else { completion(false); return }
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                         AVCaptureSession.didStopRunningNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { [self] in fail() }
                })
            }
            let success = configure(session)
            guard capture.isOpen else { cleanup(); completion(false); return }
            if success {
                for case let output as AVCaptureVideoDataOutput in session.outputs { output.setSampleBufferDelegate(self, queue: queue) }
            } else { fail() }
            completion(success && capture.isOpen)
        }
    }

    func stop() {
        capture.close()
        queue.async { [self] in cleanup() }
    }

    private func fail() {
        guard capture.isOpen, !failureReported.exchange(true, ordering: .acquiringAndReleasing) else { return }
        capture.close()
        log.error("calls: camera capture stopped or could not start")
        cleanup()
        failed()
    }

    private func cleanup() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        encoder = nil
        lastFrame = .invalid
    }

    private static func configureSession(_ session: AVCaptureSession) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        return session.isRunning
    }

    func requestKeyframe() {
        keyframeRequested.store(true, ordering: .releasing)
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard capture.isOpen, let image = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        // Cameras run at 30; the call sends `frameRate`.
        if lastFrame.isValid, (time - lastFrame).seconds < 1 / Double(frameRate) - 0.005 { return }
        lastFrame = time
        if encoder == nil {
            let width = Int32(CVPixelBufferGetWidth(image))
            let height = Int32(CVPixelBufferGetHeight(image))
            encoder = VideoEncoder(width: width, height: height, frameRate: frameRate, output: send)
            if encoder == nil { fail(); return }
        }
        if keyframeRequested.exchange(false, ordering: .acquiringAndReleasing) { encoder?.requestKeyframe() }
        encoder?.encode(image, at: time)
    }
}
