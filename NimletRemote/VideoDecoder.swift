import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Turns the host's compressed frames back into pixels on screen.
///
/// Everything here is arranged around showing a frame the instant it lands.
/// `AVSampleBufferDisplayLayer` will happily schedule playback against a
/// timebase, which is right for a movie and wrong for a mirror: any scheduling
/// is latency you added on purpose. So: no timebase, no rate, and every sample
/// tagged `DisplayImmediately`.
///
/// With one exception, and it is the exception that makes the Mac watchable
/// rather than merely drivable. While the phone is also *playing* the Mac, the
/// sound is coming out of a cushion `JitterWindow` sizes to the link — a tenth
/// of a second on a good one, nearly half on a bad one — and a picture shown
/// the instant it lands is that far ahead of it. On a terminal nobody notices.
/// On a face, everybody does. So when `hold` is non-zero each frame is held
/// until the moment its own audio is due, using the capture stamp both channels
/// already carry. `hold` is zero the rest of the time and this file behaves
/// exactly as it did: straight to the renderer, no queue, no timer.
@MainActor
final class VideoDecoder {

    enum Outcome {
        case displayed
        /// Nothing can be shown until a keyframe arrives — the renderer was
        /// flushed, or this viewer joined between keyframes.
        case needsKeyframe
    }

    weak var layer: AVSampleBufferDisplayLayer? {
        didSet {
            guard layer !== oldValue else { return }
            // A new layer starts empty, and a delta frame has nothing to draw on.
            formatDescription = nil
            parameterSets = []
            codec = nil
            waiting.removeAll()
            onShown?(nil)
            // And ask for one, here rather than at the call site. Every view
            // that shows the mirror hands this decoder its own layer — the
            // thumbnail, the detail view, the thumbnail again on the way back —
            // and the view that has just taken it cannot know whether the Mac
            // will send another frame. A still screen sends none at all, so the
            // picture would stay black until something over there moved.
            onLayerAttached?()
        }
    }

    /// Called whenever a new layer is attached and the decoder needs a
    /// keyframe to draw on it.
    var onLayerAttached: (() -> Void)?

    /// Which window's picture is on the glass, as the Mac numbered it — told
    /// at the moment a frame is handed to the renderer, after any hold, and
    /// nil when the glass has been cleared. A touch carries it back.
    var onShown: ((Int?) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var codec: ViewFrame.Codec?
    private var nextPresentation: Int64 = 0

    /// Frames built and waiting for their moment, oldest first.
    ///
    /// A queue rather than a timer per frame, and the reason is ordering: two
    /// frames whose holds differ — which is the normal case, because the hold is
    /// what corrects for their differing arrival jitter — would otherwise race,
    /// and a renderer handed samples out of order with increasing stamps shows
    /// the wrong one.
    private var waiting: [(buffer: CMSampleBuffer, dueAt: UInt64, generation: Int?)] = []
    private var drainScheduled = false

    /// A memory guard, and only that.
    ///
    /// It has to be well clear of what a legitimate hold costs, which is the
    /// hold times the frame rate: `VideoHold.maximum` at 60 fps is seventeen
    /// frames in hand at all times, and a cap anywhere near that would collapse
    /// the hold to nothing exactly when it is doing its job. Frames that are
    /// actually overdue leave through `drain`, not through here.
    private static let maxWaiting = 40

    func reset() {
        formatDescription = nil
        parameterSets = []
        codec = nil
        waiting.removeAll()
        layer?.sampleBufferRenderer.flush()
        onShown?(nil)
    }

    /// Decodes a frame, holding it for `hold` seconds so that what is on the
    /// glass and what is in the speaker are of the same moment. Zero — the
    /// default, and everything but a phone that is listening as well as looking —
    /// puts it on screen now.
    @discardableResult
    func decode(_ frame: ViewFrame, payload: Data, hold: TimeInterval = 0) -> Outcome {
        guard let layer else { return .needsKeyframe }
        let start = Instrumentation.now()

        if let sets = frame.parameterSets, !sets.isEmpty, let codec = frame.codec,
           sets != parameterSets || codec != self.codec {
            guard let format = Self.makeFormat(parameterSets: sets, codec: codec) else { return .needsKeyframe }
            formatDescription = format
            parameterSets = sets
            self.codec = codec
        }
        // Joined between keyframes: the parameter sets only ride along with one,
        // so there is nothing to decode against yet.
        guard let formatDescription else { return .needsKeyframe }

        // A renderer that has failed stays failed until flushed, and every frame
        // after that is silently discarded — a mirror frozen with no error.
        if layer.sampleBufferRenderer.status == .failed {
            remoteLog.error("view: renderer failed, flushing")
            layer.sampleBufferRenderer.flush()
            self.formatDescription = nil
            parameterSets = []
            return .needsKeyframe
        }

        guard let sampleBuffer = makeSampleBuffer(payload: payload, format: formatDescription) else {
            return .needsKeyframe
        }
        present(sampleBuffer, generation: frame.generation, after: hold, on: layer)
        Instrumentation.shared.record("view_decode_enqueue", since: start)
        return .displayed
    }

    // MARK: - When a frame goes on the glass

    private func present(_ buffer: CMSampleBuffer, generation: Int?, after hold: TimeInterval,
                         on layer: AVSampleBufferDisplayLayer) {
        // The ordinary path, unchanged: nothing is being held, so nothing waits.
        guard hold > 0 || !waiting.isEmpty else {
            layer.sampleBufferRenderer.enqueue(buffer)
            onShown?(generation)
            return
        }
        waiting.append((buffer, Instrumentation.now() &+ UInt64(max(hold, 0) * 1_000_000_000), generation))
        // A queue this long is not a hold any more, it is a leak: the drain
        // timer has stopped running, or the deadlines have run away. Empty it
        // rather than accumulate compressed frames nobody is going to see.
        if waiting.count > Self.maxWaiting {
            drain(everything: true)
        } else {
            scheduleDrain()
        }
    }

    private func scheduleDrain() {
        guard !drainScheduled, let head = waiting.first else { return }
        let now = Instrumentation.now()
        let remaining = head.dueAt > now ? Double(head.dueAt &- now) / 1_000_000_000 : 0
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.drain(everything: false)
        }
    }

    private func drain(everything: Bool) {
        guard let layer else { waiting.removeAll(); return }
        let now = Instrumentation.now()
        while let head = waiting.first, everything || head.dueAt <= now {
            waiting.removeFirst()
            layer.sampleBufferRenderer.enqueue(head.buffer)
            onShown?(head.generation)
        }
        scheduleDrain()
    }

    // MARK: - Plumbing

    private static func makeFormat(parameterSets: [Data], codec: ViewFrame.Codec) -> CMVideoFormatDescription? {
        // Copied into allocations we own: a pointer taken inside
        // `withUnsafeBytes` is only valid for that closure, and this one has to
        // still be good when the create call reads it.
        var allocations: [UnsafeMutablePointer<UInt8>] = []
        defer { allocations.forEach { $0.deallocate() } }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in parameterSets where !set.isEmpty {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            allocations.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(set.count)
        }
        guard !pointers.isEmpty else { return nil }

        var format: CMVideoFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format)
            }
        }
        guard status == noErr else {
            remoteLog.error("view: bad parameter sets \(status)")
            return nil
        }
        return format
    }

    private func makeSampleBuffer(payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // The host sends in capture order with no reordering, so a simple
        // increasing stamp is enough; nothing here is played back to a clock.
        nextPresentation += 1
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: nextPresentation, timescale: 60),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: format,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size,
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
