import Foundation
import AVFoundation
import OSLog

/// Its own logger, in the manner of `VoiceCapture`'s, and for a second reason
/// besides tidiness: this file is compiled into `nimlet-send` as well as into the
/// app, so it cannot reach for the app's `remoteLog`. That sharing is the point —
/// the diagnostic that answers "is the Mac sending silence, or nothing at all?"
/// has to decode with exactly the decoder the phone uses, or it is answering a
/// different question.
private let listenLog = Logger(subsystem: "com.renyicao.mice", category: "listen")

/// Turns the Mac's AAC packets back into samples.
///
/// No magic cookie, and that is deliberate on both sides. `AVAudioConverter`
/// does not hand over the one its encoder built, so the Mac cannot send it —
/// and AAC-LC does not need it: a sample rate, a channel count and a block
/// size, which arrive in the frame header, describe the stream completely. The
/// Mac encodes low-complexity AAC for exactly this reason.
///
/// Not an actor and not `@MainActor`: this runs on the panel-style network
/// queue, one frame at a time, because decoding on the main actor would put a
/// codec on the thread that delivers touches.
final class AudioDecoder {

    /// What the stream says it is. Rebuilt when it changes, which for a Mac that
    /// is not being reconfigured is once.
    private var described: (sampleRate: Int, channels: Int, framesPerPacket: Int)?
    private var converter: AVAudioConverter?
    private(set) var outputFormat: AVAudioFormat?
    /// Reused across packets. Sized from the codec's own maximum rather than
    /// from the largest packet seen so far, which is a number that only ever
    /// goes up at the worst possible moment.
    private var compressed: AVAudioCompressedBuffer?

    /// Float32 deinterleaved, which is what `AVAudioEngine` wants and therefore
    /// the one conversion nobody has to do twice.
    private static func pcmFormat(sampleRate: Int, channels: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(sampleRate),
                      channels: AVAudioChannelCount(channels),
                      interleaved: false)
    }

    func reset() {
        described = nil
        converter = nil
        outputFormat = nil
        compressed = nil
    }

    /// Adopts the format a frame describes. Frames that describe nothing — most
    /// of them, since the Mac only repeats this every couple of seconds — leave
    /// whatever was already set in place.
    ///
    /// Returns false for a stream this phone cannot play, so the caller can say
    /// so once instead of dropping every frame in silence.
    @discardableResult
    func adopt(_ frame: AudioFrame) -> Bool {
        guard let rate = frame.sampleRate, let channels = frame.channels else { return outputFormat != nil }
        guard frame.codec == nil || frame.codec == .aac else { return false }
        let blocks = frame.framesPerPacket ?? AudioChannel.framesPerPacket
        // Validate before signed-to-unsigned conversion or Core Audio allocation.
        guard (8_000...96_000).contains(rate), (1...AudioChannel.channels).contains(channels),
              blocks == AudioChannel.framesPerPacket else { return false }
        let wanted = (sampleRate: rate, channels: channels, framesPerPacket: blocks)
        if let described, described == wanted, converter != nil { return true }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(rate),
            mFormatID: kAudioFormatMPEG4AAC,
            // Zero is AAC-LC's object type. Everything else here is zero
            // because a compressed format has no bytes per frame and no bits
            // per channel to report.
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(blocks),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = Self.pcmFormat(sampleRate: rate, channels: channels),
              let built = AVAudioConverter(from: input, to: output) else {
            listenLog.error("listen: no AAC decoder for \(rate)Hz \(channels)ch")
            return false
        }
        described = wanted
        converter = built
        outputFormat = output
        compressed = AVAudioCompressedBuffer(format: input,
                                             packetCapacity: 1,
                                             maximumPacketSize: AudioChannel.maxPacketBytes)
        listenLog.info("listen: decoding AAC-LC \(rate)Hz \(channels)ch")
        return true
    }

    /// One packet in, one buffer of samples out.
    ///
    /// A packet at a time rather than a frame at a time, because a decoder given
    /// two packets and asked for one buffer keeps the second one — and a
    /// half-consumed frame is a click two packets later that looks like a
    /// network problem.
    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat, let compressed,
              let described, !packet.isEmpty else { return nil }
        guard packet.count <= AudioChannel.maxPacketBytes else {
            // Larger than AAC-LC allows. The length came off the wire and is
            // about to be a byte count into a buffer sized from the format, so
            // this is the check that keeps a bad frame from being a memory bug.
            listenLog.error("listen: refusing a \(packet.count)-byte packet")
            return nil
        }

        packet.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count)
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count))

        guard let out = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(described.framesPerPacket)) else { return nil }

        var pending: AVAudioCompressedBuffer? = compressed
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, outStatus in
            if let ready = pending {
                pending = nil
                outStatus.pointee = .haveData
                return ready
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        switch status {
        case .haveData, .inputRanDry:
            return out.frameLength > 0 ? out : nil
        case .error:
            listenLog.error("listen: decode failed \(failure?.localizedDescription ?? "unknown", privacy: .public)")
            // An `AVAudioConverter` that has errored does not recover, and the
            // symptom of not rebuilding it is audio that never comes back.
            reset()
            return nil
        default:
            return nil
        }
    }
}
