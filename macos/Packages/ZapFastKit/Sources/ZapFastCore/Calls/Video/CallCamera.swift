import AVFoundation
import Foundation
import OSLog

/// The Mac's camera during a call: 720p (or what the camera has) at the
/// call's frame rate, handed to the encoder, with a preview of ourselves.
nonisolated public final class CallCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ZapFast.CallCamera")
    private let frameRate: Int
    private let send: @Sendable (Data, UInt32) -> Void
    private let log = Logger(subsystem: "ZapFast", category: "Calls")
    // Touched only on `queue`.
    private var encoder: VideoEncoder?
    private var lastFrame: CMTime = .invalid

    init(frameRate: Int, send: @escaping @Sendable (Data, UInt32) -> Void) {
        self.frameRate = frameRate
        self.send = send
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
    /// quick off and on stay in order. Returns whether a camera was found.
    func start() -> Bool {
        guard AVCaptureDevice.default(for: .video) != nil else {
            log.error("calls: no camera to use")
            return false
        }
        queue.async { [self] in
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                log.error("calls: the camera could not be opened")
                return
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
        }
        return true
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            encoder = nil
            lastFrame = .invalid
        }
    }

    func requestKeyframe() {
        queue.async { [self] in encoder?.requestKeyframe() }
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let image = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        // Cameras run at 30; the call sends `frameRate`.
        if lastFrame.isValid, (time - lastFrame).seconds < 1 / Double(frameRate) - 0.005 { return }
        lastFrame = time
        if encoder == nil {
            let width = Int32(CVPixelBufferGetWidth(image))
            let height = Int32(CVPixelBufferGetHeight(image))
            encoder = VideoEncoder(width: width, height: height, frameRate: frameRate, output: send)
        }
        encoder?.encode(image, at: time)
    }
}
