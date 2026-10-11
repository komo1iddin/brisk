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
    // Submission lock owns the bounded inbox and one drain's scheduled flag.
    private var inbox = VideoFrameInbox()
    private var draining = false
    private var pendingOrientation: (stream: UInt64, turns: UInt8)?
    private var deliveringOrientation = false
    // Touched only on `queue`.
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyframe = true
    private var orientation: UInt8?
    private var keyframeRequests = VideoKeyframeRequests()
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
        submissions.withLock {
            inbox.append(.init(data: data, keyframe: keyframe, orientation: orientation))
            scheduleDrain()
        }
    }

    /// Forgets the stream: the next call starts from its first keyframe.
    public func reset() {
        submissions.withLock {
            inbox.reset()
            generation.store(inbox.stream, ordering: .releasing)
            pendingOrientation = nil
            scheduleDrain()
        }
    }

    // Called with the submission lock held. No frame Data lives in dispatch closures.
    private func scheduleDrain() {
        guard !draining else { return }
        draining = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        while let work = submissions.withLock({ () -> VideoFrameInbox.Work? in
            guard let work = inbox.next() else { draining = false; return nil }
            return work
        }) {
            guard work.stream == generation.load(ordering: .acquiring) else { continue }
            if work.reset {
                format = nil; sps = nil; pps = nil; orientation = nil
                waitingForKeyframe = true
                keyframeRequests = VideoKeyframeRequests()
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            if work.gap {
                renderer.flush()
                waitingForKeyframe = true
                if work.frame?.keyframe != true { askForKeyframe() }
            }
            guard let frame = work.frame else { continue }
            if orientation != frame.orientation {
                orientation = frame.orientation
                publishOrientation(frame.orientation, stream: work.stream)
            }
            show(frame.data, keyframe: frame.keyframe)
        }
    }

    private func publishOrientation(_ turns: UInt8, stream: UInt64) {
        submissions.withLock {
            guard stream == inbox.stream else { return }
            pendingOrientation = (stream, turns)
            guard !deliveringOrientation else { return }
            deliveringOrientation = true
            DispatchQueue.main.async { [self] in
                let latest = submissions.withLock {
                    deliveringOrientation = false
                    defer { pendingOrientation = nil }
                    return pendingOrientation
                }
                guard let latest, latest.stream == generation.load(ordering: .acquiring) else { return }
                orientationChanged(latest.turns)
            }
        }
    }

    private func askForKeyframe() {
        if keyframeRequests.shouldRequest() { requestKeyframe() }
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
                askForKeyframe()
                return
            }
            waitingForKeyframe = false
        }
        guard let format, !picture.isEmpty else { return }
        guard let sample = Self.sample(H264.avcc(picture), format: format) else {
            waitingForKeyframe = true
            askForKeyframe()
            return
        }
        guard renderer.isReadyForMoreMediaData else {
            renderer.flush()
            waitingForKeyframe = true
            askForKeyframe()
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
            format = nil
            waitingForKeyframe = true
            askForKeyframe()
            log.warning("calls: the other side's video parameters did not read")
            return
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: made) { return }
        format = made
        waitingForKeyframe = true
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
