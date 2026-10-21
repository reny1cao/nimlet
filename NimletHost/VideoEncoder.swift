import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.265/H.264 encode tuned for a screen you are watching *now*.
///
/// Every property here trades compression for latency, which is the right trade
/// when the frame is only interesting for the ~50 ms before the next one:
/// realtime mode, no frame reordering (B-frames would hold a frame or two back
/// for bitrate we do not need), and keyframes on demand rather than on a tight
/// timer.
///
/// "On demand rather than on a timer" used to be half true: there was also a
/// two-second safety net, and on a screen that is actually moving — a video
/// playing, a long scroll — that net fired every time, which made a keyframe a
/// periodic event rather than a rare one. A keyframe of a 2560-wide window is
/// tens of times the size of the delta frames around it, so every two seconds
/// the link was handed a burst it could not absorb in one frame interval; the
/// mirror stopped for as long as that took, and the audio socket sharing the
/// Wi-Fi stopped with it. That is the stutter. The net is still here, because a
/// stream nobody can join is not a stream, but it is now long enough to be what
/// it claims to be — every other path that needs a keyframe asks for one.
final class VideoEncoder {

    struct Output {
        var data: Data
        var isKeyframe: Bool
        var parameterSets: [Data]
        var codec: ViewFrame.Codec
    }

    /// Guards the session and the keyframe flag. The encode callback arrives on
    /// VideoToolbox's own queue, so everything here is touched from two threads.
    private let lock = NSLock()
    // A retained session reference alone cannot protect it from invalidation.
    // Serialize every VideoToolbox call, including rate changes and teardown.
    private let operations = NSLock()
    // Never call the transport from VideoToolbox's callback queue. Delivery can
    // retune the encoder; a synchronous VT property call from that queue can
    // deadlock its remote encoder service while CompleteFrames is waiting.
    private let delivery = DispatchQueue(label: "com.renyicao.mice.host.video-output")
    private var session: VTCompressionSession?
    private(set) var width = 0
    private(set) var height = 0
    private(set) var codec: ViewFrame.Codec = .hevc
    private var forceKeyframe = true

    deinit { invalidate() }

    /// Recreates the session when the panel's pixel size changes; a
    /// VTCompressionSession is fixed at its dimensions.
    func prepare(width: Int, height: Int, bitrate: Int, fps: Double) -> Bool {
        operations.lock()
        defer { operations.unlock() }
        if lock.withLock({ session != nil && width == self.width && height == self.height }) { return true }
        invalidateSession()

        for candidate in [ViewFrame.Codec.hevc, .h264] {
            guard let created = Self.makeSession(width: width, height: height, codec: candidate) else { continue }
            configure(created, bitrate: bitrate, fps: fps, codec: candidate)
            guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
                VTCompressionSessionInvalidate(created)
                continue
            }
            lock.withLock {
                self.session = created
                self.codec = candidate
                self.width = width
                self.height = height
                self.forceKeyframe = true
            }
            miceLog.info("view: encoder \(candidate.rawValue, privacy: .public) \(width)x\(height) @ \(bitrate / 1000) kbps")
            return true
        }
        miceLog.error("view: no encoder available for \(width)x\(height)")
        return false
    }

    private static func makeSession(width: Int, height: Int, codec: ViewFrame.Codec) -> VTCompressionSession? {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            // nil callback means the block-based encode entry point, which keeps
            // the output next to the call site instead of in a C trampoline.
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        return status == noErr ? session : nil
    }

    private func configure(_ session: VTCompressionSession, bitrate: Int, fps: Double, codec: ViewFrame.Codec) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // The one that matters most for feel: reordering buys bitrate by holding
        // frames back, and a frame held back is latency you cannot get rid of.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // Every path that leaves a viewer unable to build the next frame asks
        // for a keyframe explicitly: a viewer attaching, resizing or flushing
        // its renderer, the mirror changing windows, a frame this side had to
        // throw away, and a phone whose reader desynced. So this is the net for
        // the one case none of those cover — a stream corrupted in a way nobody
        // noticed — and a net does not need to fire every two seconds.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: Self.keyframeSafetySeconds))
        apply(bitrate: bitrate, fps: fps, to: session)
    }

    /// The rate, on a session that may already be running.
    ///
    /// Settable while encoding, which is what makes measured bitrate control
    /// possible at all: the alternative is tearing down the session, and a new
    /// session starts with a keyframe — so an encoder that adapted by rebuilding
    /// itself would answer congestion with the largest frame it can produce.
    private func apply(bitrate: Int, fps: Double, to session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        // How the rate allocator turns the bitrate above into a per-frame size.
        // It has to be the rate that is actually reaching the phone: told 60
        // while twenty go out, it divides by sixty, asks itself for frames a
        // third the size it can make, gives up on the target and emits sixty
        // anyway — 1.5 Mbps requested, 4.5 measured. See `VideoPacer`.
        set(kVTCompressionPropertyKey_ExpectedFrameRate,
            NSNumber(value: min(max(fps, 5), 60)))
        // Two windows, and the short one is the one that matters here. A single
        // one-second limit lets a keyframe spend most of a second's budget in
        // one frame, which is precisely the burst that stalls the link; capping
        // a quarter-second as well bounds what any one moment can cost while
        // still leaving headroom over the average, without which a keyframe
        // takes the whole budget and the frames after it come back soft.
        let bytesPerSecond = Double(bitrate) / 8
        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: Int(bytesPerSecond * 0.25 * 2.0)), NSNumber(value: 0.25),
             NSNumber(value: Int(bytesPerSecond * 1.3)), NSNumber(value: 1.0)] as CFArray)
    }

    /// Long enough that a moving screen never hits it, short enough that a
    /// picture broken by something nobody detected repairs itself rather than
    /// staying broken.
    private static let keyframeSafetySeconds = 10.0

    /// Retunes a live session. No-op when there is no session, which is the
    /// ordinary case between a viewer leaving and the next one arriving.
    func retune(bitrate: Int, fps: Double) {
        operations.lock()
        defer { operations.unlock() }
        let session = lock.withLock { self.session }
        guard let session else { return }
        apply(bitrate: bitrate, fps: fps, to: session)
    }

    func requestKeyframe() { lock.withLock { forceKeyframe = true } }

    func invalidate() {
        operations.lock()
        defer { operations.unlock() }
        invalidateSession()
    }

    /// Called with `operations` held. Completion callbacks only enqueue delivery.
    private func invalidateSession() {
        let session: VTCompressionSession? = lock.withLock {
            let existing = self.session
            self.session = nil
            self.width = 0
            self.height = 0
            return existing
        }
        guard let session else { return }
        // Drain the VT callbacks before teardown. Their deliveries are queued
        // separately, so callers must reject outputs from a retired stream.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// Asynchronous, because VideoToolbox is.
    ///
    /// `VTCompressionSessionEncodeFrame` returns as soon as the frame is
    /// submitted and calls the handler later on its own queue. Reading the
    /// handler's result straight after the call — which is what this used to do
    /// — meant almost every frame was still being encoded and came back empty:
    /// 58 frames a second captured, roughly one every five seconds delivered.
    /// The occasional one that worked was a handler that happened to land first.
    ///
    /// Returns false when the frame was not submitted at all, so the caller can
    /// release the slot it reserved.
    ///
    /// `output` is called exactly once for every frame that *was* submitted, and
    /// receives nil for one that produced nothing. That is not tidiness, it is
    /// the difference between a mirror and a still picture. VideoToolbox's
    /// handler is documented to run for every submitted frame — with `noErr` and
    /// a nil sample buffer when its own rate controller decided to drop one —
    /// and this used to return early in that case, which meant the caller's
    /// in-flight count was never given back. One frame dropped inside the
    /// encoder and nothing was ever encoded again until something restarted the
    /// capture. Rarer with a loose rate limit than a tight one, which is exactly
    /// why it surfaced when the limits were tightened rather than being a new
    /// fault.
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime,
                output: @escaping (Output?) -> Void) -> Bool {
        operations.lock()
        defer { operations.unlock() }
        let (session, wantsKeyframe, codec) = lock.withLock {
            () -> (VTCompressionSession?, Bool, ViewFrame.Codec) in
            let keyframe = forceKeyframe
            forceKeyframe = false
            return (self.session, keyframe, self.codec)
        }
        guard let session else { return false }
        let delivery = self.delivery
        let deliver: (Output?) -> Void = { result in
            delivery.async { output(result) }
        }

        let properties: CFDictionary? = wantsKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil
        let start = Instrumentation.now()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil) { [weak self] encodeStatus, flags, sampleBuffer in
                Instrumentation.shared.record("view_encode", since: start)
                if encodeStatus != noErr {
                    miceLog.error("view: encode returned \(encodeStatus)")
                    // The session may be in a state the next delta cannot be
                    // built on, so whatever comes out next stands on its own.
                    self?.requestKeyframe()
                    deliver(nil)
                    return
                }
                guard let sampleBuffer else {
                    // The rate controller dropped it. A frame the encoder never
                    // emitted is not in anybody's reference chain, so there is
                    // nothing to repair — except the request that came with it:
                    // `forceKeyframe` was consumed on submission, so a viewer
                    // waiting for its first picture would wait for the ten-second
                    // safety net if this were let go.
                    if wantsKeyframe { self?.requestKeyframe() }
                    if Instrumentation.isEnabled, flags.contains(.frameDropped) {
                        miceLog.info("view: encoder dropped a frame to hold the rate")
                    }
                    deliver(nil)
                    return
                }
                guard let packaged = Self.package(sampleBuffer, codec: codec) else {
                    // Emitted by the encoder and lost on this side, which is the
                    // one case that *does* break the chain: it is in the
                    // reference picture and the phone will never see it.
                    self?.requestKeyframe()
                    deliver(nil)
                    return
                }
                deliver(packaged)
            }
        if status != noErr {
            miceLog.error("view: encode failed \(status)")
            // Whatever comes next has to stand on its own.
            requestKeyframe()
            return false
        }
        return true
    }

    private static func package(_ sampleBuffer: CMSampleBuffer, codec: ViewFrame.Codec) -> Output? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(of: format, codec: codec)
        }
        return Output(data: data, isKeyframe: isKeyframe, parameterSets: parameterSets, codec: codec)
    }

    /// VPS/SPS/PPS, resent with every keyframe. A viewer can then attach at any
    /// moment without a side-channel handshake for the format description.
    private static func parameterSets(of format: CMFormatDescription, codec: ViewFrame.Codec) -> [Data] {
        var count = 0
        let probe: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                                                                 parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                                 parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil)
        guard probe == noErr else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                     parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                     parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}
