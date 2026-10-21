import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures what this Mac is playing — all of it, from every app.
///
/// A display filter rather than a window or an application one, and that is the
/// whole design. Nimlet's other captures are about one target because text goes to
/// one target; sound is not like that. The chime that says an agent finished
/// comes from a different process than the agent, a video call is two apps
/// deep, and "hear my Mac" does not mean "hear whichever app I last tapped".
/// One mix, everything in it, and it does not change when the dock does.
///
/// ScreenCaptureKit rather than a Core Audio process tap, for one reason worth
/// stating: Nimlet already holds Screen Recording, asks for it in a place the user
/// understands, and reports it on the phone when it is missing. A tap would be a
/// second audio-capture grant with its own prompt, its own silent-failure mode
/// and its own line in the privacy documentation, to reach the same samples.
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {

    private let queue = DispatchQueue(label: "com.renyicao.mice.host.audio")
    /// Interleaved or not, whatever ScreenCaptureKit handed over, plus the host
    /// uptime it arrived at — stamped here rather than after the encoder so the
    /// number the phone shows is the delay of the whole path.
    private let onBuffer: (AVAudioPCMBuffer, UInt64) -> Void
    private let onState: (String) -> Void

    /// The live stream, whether one is wanted, and whether one is being opened
    /// right now — all three under one lock.
    ///
    /// Not fussiness: `open` is async, so it necessarily runs off the capture
    /// queue, while the sample callback and the watchdog both run on it. Every
    /// one of these is written on one thread and read on another, and the
    /// identity check in the sample callback — the thing that keeps a replaced
    /// stream's samples out of the mix — is only as good as the read behind it.
    private let lock = NSLock()
    private var stream: SCStream?
    private var wantsStream = false
    private var isOpening = false
    /// Rebuilt only when the stream's format changes, which for a configured
    /// capture is once. Building an `AVAudioFormat` per buffer would be an
    /// allocation a hundred times a second to describe something constant.
    /// Touched only on the capture queue, where the samples arrive.
    private var format: AVAudioFormat?
    private var watchdog: DispatchSourceTimer?

    init(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void,
         onState: @escaping (String) -> Void) {
        self.onBuffer = onBuffer
        self.onState = onState
    }

    // MARK: - Lifecycle

    func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            defer { wantsStream = true }
            return wantsStream
        }
        guard !alreadyRunning else { return }
        guard ScreenAccess.isGranted else {
            // Puts Nimlet in the Screen Recording list and shows the prompt, so
            // there is something for the user to switch on. Same treatment as
            // the mirror, because it is the same grant.
            lock.withLock { wantsStream = false }
            ScreenAccess.requestOnceIfNeeded()
            onState("Grant Screen Recording to Nimlet on your Mac, then relaunch it")
            return
        }
        Task { await open() }
        startWatchdog()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        let stream = lock.withLock { () -> SCStream? in
            wantsStream = false
            defer { self.stream = nil }
            return self.stream
        }
        Task { try? await stream?.stopCapture() }
    }

    /// Audio can stop without anybody being told twice.
    ///
    /// The display sleeping, a monitor being unplugged, the Mac waking from a
    /// nap — each of those can end an `SCStream`, and `didStopWithError` fires
    /// once and then there is nothing left to fire. A phone in a pocket has no
    /// way to ask for a retry, so the Mac keeps trying on its own for as long as
    /// somebody is listening. Two seconds, which is slow enough to be free and
    /// quick enough that waking the Mac and hearing it are the same gesture.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ self.wantsStream && self.stream == nil }) else { return }
            Task { await self.open() }
        }
        timer.resume()
        watchdog = timer
    }

    private func open() async {
        let claimed = lock.withLock { () -> Bool in
            guard !isOpening, stream == nil, wantsStream else { return false }
            isOpening = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { isOpening = false } }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false),
              let display = content.displays.first else {
            onState("No display to capture audio from")
            return
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // A screen output as well, and it is not vestigial: an `SCStream` is
            // a screen capture that happens to also carry audio, and one asked
            // for a display with nothing collecting its frames is not a
            // configuration Apple documents as supported. Two pixels once a
            // second is the cheapest way to be inside the supported shape, and
            // the frames are dropped where they arrive.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // Opening takes long enough for the last listener to have left in
            // the middle of it, and a stream nobody claims is a recording
            // indicator lit for nothing.
            guard lock.withLock({ () -> Bool in
                guard wantsStream else { return false }
                self.stream = stream
                return true
            }) else {
                try? await stream.stopCapture()
                return
            }
            miceLog.info("listen: capturing this Mac's output at \(AudioChannel.sampleRate)Hz")
        } catch {
            lock.withLock { self.stream = nil }
            // Reported once per failure, not per retry: the watchdog will be
            // back in two seconds and a phone does not need a new sentence each
            // time to say the same thing.
            miceLog.error("listen: capture failed \(error.localizedDescription, privacy: .public)")
            onState("Couldn't capture this Mac's audio: \(error.localizedDescription)")
        }
    }

    private func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = AudioChannel.sampleRate
        config.channelCount = AudioChannel.channels
        // Or Nimlet's own output would be in the mix it is sending, which on a Mac
        // whose output happens to be routed back through anything is a feedback
        // loop with a phone at one end of it.
        config.excludesCurrentProcessAudio = true
        // The video side of a capture nobody is watching. Two pixels a second,
        // dropped on arrival — small enough that the window server's scaler and
        // the memory for it round to nothing.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3
        return config
    }

    // MARK: - Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // The 2×2 picture. Asked for so the stream is a shape Apple supports,
        // never looked at.
        guard type == .audio else { return }
        // Stopping an `SCStream` is asynchronous, so a stream that has been
        // replaced goes on delivering for a while. Identity is the only thing
        // that separates its samples from the current one's.
        guard lock.withLock({ stream === self.stream }) else { return }
        let arrived = Instrumentation.now()

        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription else { return }
        if format == nil || format?.streamDescription.pointee.mSampleRate != asbd.mSampleRate
            || format?.channelCount != AVAudioChannelCount(asbd.mChannelsPerFrame) {
            format = AVAudioFormat(streamDescription: &asbd)
            miceLog.info("listen: \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch from ScreenCaptureKit")
        }
        guard let format else { return }

        // No copy: the buffer list points into the sample buffer's block
        // buffer, which is alive for the length of this closure, and the
        // encoder consumes it inside it. A hundred copies a second of audio
        // nobody has asked to keep would be a hundred allocations for nothing.
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: list.unsafePointer) else { return }
            onBuffer(pcm, arrived)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        miceLog.error("listen: stream stopped \(error.localizedDescription, privacy: .public)")
        guard lock.withLock({ () -> Bool in
            guard stream === self.stream else { return false }
            self.stream = nil
            return true
        }) else { return }
        // `format` is deliberately left alone. This callback arrives on a queue
        // of ScreenCaptureKit's choosing, not the one the samples come in on, and
        // clearing it from here would be a write racing a read for no gain: the
        // format check in `didOutputSampleBuffer` rebuilds it when it changes
        // anyway, which is the only case where a stale one would matter.
        //
        // No state frame either. The watchdog will have it back inside two seconds,
        // and a phone that is playing audio does not want a sentence on screen
        // about a gap it may not even have heard.
    }
}
