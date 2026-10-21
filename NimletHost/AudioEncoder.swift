import Foundation
import AVFoundation

/// AAC-LC encode of whatever the Mac is playing.
///
/// Compressed rather than sent as samples, and the number is the argument: 48 kHz
/// stereo Float32 is 3 Mbps, Int16 is 1.5, and AAC at the setting below is 0.1.
/// On the desk none of that matters; over the away path it is the difference
/// between a feature and 700 MB an hour of somebody's cellular plan.
///
/// AAC-LC specifically, not HE-AAC: the low-complexity profile is decodable from
/// nothing but a sample rate and a channel count, which means the phone builds
/// its decoder's input format out of three integers in a frame header instead of
/// needing a magic cookie this side cannot hand over — `AVAudioConverter` does
/// not expose the one its encoder made.
final class AudioEncoder {

    struct Output {
        /// The packets, concatenated.
        var data: Data
        /// And their lengths, in order. AAC is variable-rate, so this is the
        /// only thing that says where one ends.
        var packets: [Int]
    }

    /// Transparent enough for music on a phone speaker or a pair of AirPods, and
    /// 12 KB/s.
    ///   defaults write com.renyicao.mice.host mice.listenBitrate -int 128000
    private static let bitrate: Int = {
        let override = UserDefaults.standard.integer(forKey: "mice.listenBitrate")
        return (32_000...320_000).contains(override) ? override : 96_000
    }()

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let aacFormat: AVAudioFormat?

    /// One buffer, reused. It is written and read inside `encode`, which runs
    /// only on the capture queue, so there is nothing to share it with — and
    /// allocating a fresh one a hundred times a second to hold a few hundred
    /// bytes is the kind of cost that only shows up as a warm phone at the other
    /// end of the afternoon.
    private var scratch: AVAudioCompressedBuffer?

    init() {
        aacFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioChannel.sampleRate,
            AVNumberOfChannelsKey: AudioChannel.channels,
        ])
    }

    /// Everything the phone needs to build the matching decoder. Nil until the
    /// first buffer has been through, because until then this side does not know
    /// what it is encoding either.
    var describedFormat: (sampleRate: Int, channels: Int, framesPerPacket: Int)? {
        guard let aacFormat, converter != nil else { return nil }
        let asbd = aacFormat.streamDescription.pointee
        return (Int(asbd.mSampleRate),
                Int(asbd.mChannelsPerFrame),
                Int(asbd.mFramesPerPacket) > 0 ? Int(asbd.mFramesPerPacket) : AudioChannel.framesPerPacket)
    }

    /// Encodes one buffer, and returns nothing most of the time.
    ///
    /// That is not a failure: ScreenCaptureKit delivers about 10 ms of audio at a
    /// time and an AAC packet is 21.3 ms, so roughly every other call is the
    /// converter quietly accumulating. The alternative — staging the samples here
    /// until there are 1024 of them — is a second buffer and a second copy to do
    /// what the converter already does.
    func encode(_ buffer: AVAudioPCMBuffer) -> Output? {
        guard buffer.frameLength > 0, let aacFormat else { return nil }
        guard let converter = converter(for: buffer.format) else { return nil }

        // Room for a few. The converter fills the output buffer as far as the
        // input allows, so a capacity of one would leave a packet inside it on
        // any call that happened to complete two.
        let scratch = scratch ?? AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: AVAudioPacketCount(4),
            maximumPacketSize: converter.maximumOutputPacketSize)
        self.scratch = scratch
        scratch.packetCount = 0
        scratch.byteLength = 0

        var pending: AVAudioPCMBuffer? = buffer
        var failure: NSError?
        let status = converter.convert(to: scratch, error: &failure) { _, outStatus in
            if let ready = pending {
                pending = nil
                outStatus.pointee = .haveData
                return ready
            }
            // The honest answer, and the one that makes this work: "I have no
            // more input right now" makes the converter hand back the packets it
            // could complete and keep the rest. `.endOfStream` would flush the
            // encoder and end it, which for a live capture would mean tearing
            // down and rebuilding a codec a hundred times a second.
            outStatus.pointee = .noDataNow
            return nil
        }

        switch status {
        case .haveData, .inputRanDry:
            break
        case .endOfStream:
            return nil
        case .error:
            miceLog.error("listen: encode failed \(failure?.localizedDescription ?? "unknown", privacy: .public)")
            // Rebuilt on the next buffer. An `AVAudioConverter` that has errored
            // does not recover on its own, and a stream that goes silent forever
            // after one bad buffer is the failure this line exists to prevent.
            self.converter = nil
            sourceFormat = nil
            self.scratch = nil
            return nil
        @unknown default:
            return nil
        }

        guard scratch.packetCount > 0, let descriptions = scratch.packetDescriptions else { return nil }
        var packets: [Int] = []
        packets.reserveCapacity(Int(scratch.packetCount))
        for index in 0..<Int(scratch.packetCount) {
            packets.append(Int(descriptions[index].mDataByteSize))
        }
        // The descriptions carry a start offset each, and for a buffer the
        // converter just filled they are contiguous from zero — but copying
        // `byteLength` bytes and trusting that is exactly the assumption that
        // turns into a click nobody can find. Copy each packet from where it
        // says it is.
        var data = Data(capacity: Int(scratch.byteLength))
        let bytes = scratch.data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<Int(scratch.packetCount) {
            let description = descriptions[index]
            data.append(bytes + Int(description.mStartOffset), count: Int(description.mDataByteSize))
        }
        return Output(data: data, packets: packets)
    }

    /// Drops the codec, so the next buffer builds a fresh one.
    func invalidate() {
        converter = nil
        sourceFormat = nil
        scratch = nil
    }

    // MARK: - The codec

    private func converter(for source: AVAudioFormat) -> AVAudioConverter? {
        if let converter, let sourceFormat, sourceFormat == source { return converter }
        guard let aacFormat, let built = AVAudioConverter(from: source, to: aacFormat) else {
            miceLog.error("listen: no AAC encoder for \(source, privacy: .public)")
            return nil
        }
        // Long-term average rather than constant, and it is what makes silence
        // free. A Mac that is not playing anything still produces samples — the
        // display's audio stream never stops — and a constant-rate encoder pads
        // them to the full 96 kbps. This lets a quiet passage cost tens of bytes
        // a packet while holding the average where it was asked to be.
        built.bitRateStrategy = AVAudioBitRateStrategy_LongTermAverage
        // Only a value the encoder will accept: setting an inapplicable rate is
        // ignored, which leaves the default in force and nothing to say so.
        let applicable = built.applicableEncodeBitRates?.map(\.intValue) ?? []
        built.bitRate = applicable.isEmpty
            ? Self.bitrate
            : applicable.min { abs($0 - Self.bitrate) < abs($1 - Self.bitrate) } ?? Self.bitrate
        converter = built
        sourceFormat = source
        miceLog.info("listen: encoder AAC-LC \(built.bitRate / 1000) kbps from \(Int(source.sampleRate))Hz \(source.channelCount)ch")
        return built
    }
}
