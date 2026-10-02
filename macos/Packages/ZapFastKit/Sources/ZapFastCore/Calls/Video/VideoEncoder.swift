import CoreMedia
import Foundation
import OSLog
import Synchronization
import VideoToolbox

/// The camera's frames as WhatsApp sends video: H.264 Constrained Baseline
/// at up to 720p, a keyframe every three seconds (or when the other side
/// asks), the parameter sets before each, and Annex-B access units.
nonisolated final class VideoEncoder: @unchecked Sendable {
    /// What WhatsApp's high-quality mode sends (1280x720 at 20 fps, about
    /// 2 Mbit/s); a little less, for the uplinks calls usually meet.
    static let bitrate = 1_500_000
    static let keyframeSeconds = 3

    private let session: VTCompressionSession
    private let output: @Sendable (Data, UInt32) -> Void
    private let forceKeyframe = Atomic<Bool>(true)
    private let log = Logger(subsystem: "ZapFast", category: "Calls")

    /// `output` gets each access unit and its capture time on the 90 kHz
    /// clock, on VideoToolbox's thread.
    init?(width: Int32, height: Int32, frameRate: Int, output: @escaping @Sendable (Data, UInt32) -> Void) {
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made
        )
        guard status == noErr, let made else { return nil }
        session = made
        self.output = output
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameRate * Self.keyframeSeconds,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Self.keyframeSeconds,
            kVTCompressionPropertyKey_AverageBitRate: Self.bitrate,
            // Bursts of up to half again the average over a second.
            kVTCompressionPropertyKey_DataRateLimits: [Self.bitrate * 3 / 16, 1] as CFArray,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The next frame is a keyframe: the other side lost one, or just
    /// started watching.
    func requestKeyframe() {
        forceKeyframe.store(true, ordering: .relaxed)
    }

    func encode(_ image: CVImageBuffer, at time: CMTime) {
        let force = forceKeyframe.exchange(false, ordering: .relaxed)
        let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let timestamp = UInt32(truncatingIfNeeded: Int64((time.seconds * 90_000).rounded()))
        let output = output
        let log = log
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let unit = Self.accessUnit(sample) else {
                log.warning("calls: a camera frame did not encode")
                return
            }
            output(unit, timestamp)
        }
        if status != noErr, force { forceKeyframe.store(true, ordering: .relaxed) }
    }

    /// The sample as an Annex-B access unit, with the parameter sets first
    /// when it is a keyframe.
    static func accessUnit(_ sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return nil }
        var units: [Data] = []
        if isKeyframe(sample), let format = sample.formatDescription {
            units += parameterSets(format)
        }
        units += H264.units(avcc: data)
        return units.isEmpty ? nil : H264.annexB(units)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }
        return (0 ..< count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
