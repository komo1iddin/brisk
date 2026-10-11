import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Synchronization

/// The other side's video: Annex-B access units in, pictures out through an
/// `AVSampleBufferDisplayLayer`, which decodes H.264 itself. A lost or
/// undecodable unit asks for a keyframe and skips to it.
nonisolated public final class VideoRenderer: @unchecked Sendable {
    /// The layer the call window shows.
    public let layer: AVSampleBufferDisplayLayer
    /// The layer's decoder, taken on the main actor once; enqueueing into it
    /// is safe from any thread.
    nonisolated(unsafe) private let renderer: AVSampleBufferVideoRenderer

    private let queue = DispatchQueue(label: "ZapFast.CallVideo")
    // Keeps reset and frame submission ordered even with concurrent callers.
    private let submissions = NSLock()
    private let generation = Atomic<UInt64>(0)
    // Touched only on `queue`.
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyframe = true
    private var orientation: UInt8?
    private let log = Logger(subsystem: "ZapFast", category: "Calls")
    /// Asks the other side for a keyframe.
    let requestKeyframe: @Sendable () -> Void
    /// The sender's rotation changed, in quarter turns clockwise; called on
    /// the main queue. Set once, before any video arrives.
    nonisolated(unsafe) var orientationChanged: @Sendable (UInt8) -> Void = { _ in }

    @MainActor
    init(requestKeyframe: @escaping @Sendable () -> Void, onOrientation: @escaping @Sendable (UInt8) -> Void) {
        self.requestKeyframe = requestKeyframe
        orientationChanged = onOrientation
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        self.layer = layer
        renderer = layer.sampleBufferRenderer
    }

    /// Decodes and shows one access unit, on the renderer's own queue.
    public func enqueue(_ data: Data, keyframe: Bool, orientation: UInt8) {
        submissions.lock()
        defer { submissions.unlock() }
        let stream = generation.load(ordering: .acquiring)
        queue.async { [self] in
            guard stream == generation.load(ordering: .acquiring) else { return }
            if self.orientation != orientation {
                self.orientation = orientation
                let changed = orientationChanged
                DispatchQueue.main.async { [self] in
                    guard stream == generation.load(ordering: .acquiring) else { return }
                    changed(orientation)
                }
            }
            show(data, keyframe: keyframe)
        }
    }

    /// Forgets the stream: the next call starts from its first keyframe.
    public func reset() {
        submissions.lock()
        defer { submissions.unlock() }
        generation.store(generation.load(ordering: .relaxed) &+ 1, ordering: .releasing)
        queue.async { [self] in
            format = nil
            sps = nil
            pps = nil
            waitingForKeyframe = true
            orientation = nil
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func show(_ data: Data, keyframe: Bool) {
        let units = H264.units(annexB: data)
        var picture: [Data] = []
        for unit in units {
            switch H264.type(of: unit) {
            case H264.Unit.sps.rawValue: sps = unit
            case H264.Unit.pps.rawValue: pps = unit
            case H264.Unit.delimiter.rawValue: continue
            default: picture.append(unit)
            }
        }
        if units.contains(where: { H264.type(of: $0) == H264.Unit.sps.rawValue || H264.type(of: $0) == H264.Unit.pps.rawValue }) {
            updateFormat()
        }
        if renderer.status == .failed {
            renderer.flush()
            waitingForKeyframe = true
        }
        let hasIDR = picture.contains { H264.type(of: $0) == H264.Unit.idr.rawValue }
        if waitingForKeyframe {
            guard hasIDR || keyframe, format != nil else {
                requestKeyframe()
                return
            }
            waitingForKeyframe = false
        }
        guard let format, !picture.isEmpty, let sample = Self.sample(H264.avcc(picture), format: format) else {
            return
        }
        renderer.enqueue(sample)
    }

    private func updateFormat() {
        guard let sps, let pps else { return }
        var made: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made
                )
            }
        }
        guard status == noErr, let made else {
            log.warning("calls: the other side's video parameters did not read")
            return
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: made) { return }
        format = made
    }

    /// One AVCC picture as a sample to show at once.
    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}
