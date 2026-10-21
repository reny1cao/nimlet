import Foundation
import AVFoundation
import Speech
import Combine
import OSLog

private let voiceLog = Logger(subsystem: "com.renyicao.mice", category: "voice")

/// Hold-to-talk dictation, using on-device transcription when available.
///
/// Primary path is iOS 26's `SpeechAnalyzer` + `SpeechTranscriber`: it has no
/// one-minute session cap, and unlike `SFSpeechRecognizer` it does not require
/// the user to have switched on Siri or keyboard dictation first. The older API
/// is kept as a fallback because the transcriber's language assets can be
/// missing (notably in the Simulator, which cannot always fetch them).
@MainActor
final class VoiceCapture: ObservableObject {

    enum Engine: String {
        case speechAnalyzer = "on-device (SpeechAnalyzer)"
        case legacy = "fallback (SFSpeechRecognizer)"
        case none = "unavailable"
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var partialText = ""
    /// Not published: no view shows which recogniser won, and publishing it
    /// invalidated every observer of this object at the start of each recording
    /// for state nothing on screen depends on.
    private(set) var engine: Engine = .none
    @Published private(set) var errorMessage: String?
    @Published private(set) var level: Float = 0
    /// The recording ended itself at the cap while the finger was still down.
    /// Published so the overlay can stay up and say so instead of vanishing
    /// mid-sentence.
    @Published private(set) var hitDurationLimit = false

    /// A hold this long is somebody's pocket, not a sentence.
    static let maxRecordingSeconds: TimeInterval = 90
    /// Whatever survives the duration cap still has to be safe to paste at a
    /// shell prompt.
    static let maxTranscriptCharacters = 1200

    private let audioEngine = AVAudioEngine()
    /// Bumped on every stop/cancel. `start()` does async work (permission
    /// prompts, asset downloads) during which the finger may already be gone —
    /// a stale generation means "you were cancelled, don't open the mic".
    private var generation = 0
    private var permissionsPrimed = false
    private var durationLimitTask: Task<Void, Never>?
    /// Set when the duration cap ended the recording while the finger was still
    /// down, so the release still delivers what was said before it.
    private var pendingTranscript: String?
    /// The drain the duration cap started, while it is still running.
    ///
    /// `finishCapture()` suspends for as long as the engine takes to produce
    /// its last result — an analyzer finalize, or up to 2s on the legacy path —
    /// and a finger lifting inside that window has to wait for it. Without this
    /// the release found `isRecording` and `isPreparing` already false, read
    /// that as "nothing was captured", and threw a 90-second dictation away.
    private var finishTask: Task<String?, Never>?

    // SpeechAnalyzer path
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var finalizedText = ""

    // Legacy path
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyRecognizer: SFSpeechRecognizer?

    // MARK: - Permissions

    /// Called once the phone connects, so the first hold-to-talk isn't eaten by
    /// a permission alert. Getting prompted mid-gesture means the first thing
    /// you ever try to dictate is silently lost.
    func primePermissions() async {
        guard !permissionsPrimed else { return }
        permissionsPrimed = true
        _ = await requestPermissions()
    }

    func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard mic else {
            errorMessage = "Microphone access denied"
            return false
        }
        // Only the legacy path needs this authorization, but asking up front
        // means the fallback is ready if the modern one can't load assets.
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return true
    }

    // MARK: - Recording

    /// `vocabulary` biases transcription toward the active target's project —
    /// identifiers are exactly what dictation gets wrong, and they are
    /// different per repository.
    func start(vocabulary terms: [String] = []) async {
        guard !isRecording, !isPreparing else { return }
        generation += 1
        let token = generation
        isPreparing = true
        errorMessage = nil
        partialText = ""
        finalizedText = ""
        pendingTranscript = nil
        // A drain left over from the previous hold no longer has anyone to
        // deliver to; detaching it here stops its result being stashed as this
        // hold's pending transcript.
        finishTask = nil
        hitDurationLimit = false
        defer { isPreparing = false }

        permissionsPrimed = true
        guard await requestPermissions() else { return }
        guard token == generation else { return }

        do {
            try configureSession()
            if await startAnalyzer(vocabulary: terms) {
                engine = .speechAnalyzer
            } else if startLegacy() {
                engine = .legacy
            } else {
                engine = .none
                errorMessage = errorMessage ?? "No speech recognizer available"
                deactivateSession()
                return
            }
            // Released while we were still setting up: tear down rather than
            // leaving a hot mic behind.
            guard token == generation else {
                await cleanup()
                return
            }
            try audioEngine.start()
            isRecording = true
            startDurationLimit(token: token)
            voiceLog.info("recording started via \(self.engine.rawValue, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            await cleanup()
        }
    }

    /// Stops capture and returns the final transcript, or nil if nothing usable.
    @discardableResult
    func stop() async -> String? {
        // The duration cap may have ended the recording already; the release
        // still has to hand over what it captured — including while that drain
        // is still in flight, which is the common case for a hold that ran the
        // clock out.
        if hitDurationLimit {
            hitDurationLimit = false
            if let task = finishTask {
                finishTask = nil
                pendingTranscript = nil
                return await task.value
            }
            let pending = pendingTranscript
            pendingTranscript = nil
            return pending
        }
        guard isRecording || isPreparing else { return nil }
        // Invalidates any start() still in flight.
        generation += 1
        let wasRecording = isRecording
        isRecording = false
        guard wasRecording else {
            // Released before the mic ever opened — nothing was captured.
            await cleanup()
            return nil
        }
        return await finishCapture()
    }

    /// Drains whichever engine is running and returns its transcript, capped.
    private func finishCapture() async -> String? {
        durationLimitTask?.cancel()
        durationLimitTask = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        var text: String?
        switch engine {
        case .speechAnalyzer:
            inputContinuation?.finish()
            inputContinuation = nil
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            text = finalizedText.isEmpty ? partialText : finalizedText

        case .legacy:
            legacyRequest?.endAudio()
            // endAudio() is async: the final result lands a moment later, so
            // wait for the task to settle rather than reading a stale partial.
            for _ in 0..<40 {
                if legacyTask?.state == .completed { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            text = partialText

        case .none:
            text = nil
        }

        await cleanup()

        var trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Self.maxTranscriptCharacters {
            trimmed = Self.capped(trimmed)
            errorMessage = "Trimmed to \(Self.maxTranscriptCharacters) characters"
        }
        // Length only. This is the one drain path for both engines, so logging
        // the text here put every dictated sentence into the device log — from
        // the modern analyzer too, which PRIVACY.md explicitly promises never
        // does that. A character count answers "did anything come out?" without
        // recording what was said.
        voiceLog.info("transcript: \(trimmed.count) chars")
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Cut at a word boundary: half a word arriving at a shell prompt reads as
    /// a bug rather than as a limit.
    private static func capped(_ text: String) -> String {
        let clipped = text.prefix(maxTranscriptCharacters)
        guard let space = clipped.lastIndex(of: " ") else { return String(clipped) }
        return String(clipped[clipped.startIndex..<space])
    }

    private func startDurationLimit(token: Int) {
        durationLimitTask?.cancel()
        durationLimitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingSeconds))
            guard !Task.isCancelled, let self else { return }
            await self.stopAtDurationLimit(token: token)
        }
    }

    /// Ends the recording without the finger having lifted. Holding the button
    /// and walking away used to record indefinitely and then paste the lot.
    private func stopAtDurationLimit(token: Int) async {
        guard token == generation, isRecording else { return }
        generation += 1
        isRecording = false
        // Dropped rather than cancelled: this *is* that task, and cancelling it
        // would abort the drain below before the transcript came out.
        durationLimitTask = nil
        // Both of these are published *before* the drain is awaited, with no
        // suspension point between them and `isRecording = false`. They used to
        // be set afterwards, which left a window — as long as the engine took to
        // finalize — where a release saw an idle-looking state and discarded the
        // whole dictation without so much as an error.
        hitDurationLimit = true
        errorMessage = "Stopped at \(Int(Self.maxRecordingSeconds))s — tap Send to send it"

        let task = Task { @MainActor [weak self] in
            guard let self else { return String?.none }
            return await self.finishCapture()
        }
        finishTask = task
        let text = await task.value
        // A release that landed mid-drain has already taken this transcript
        // through `stop()` and detached the task; leaving a copy behind would
        // hand the same words to the *next* hold.
        guard finishTask == task else { return }
        finishTask = nil
        pendingTranscript = text
    }

    func cancel() async {
        generation += 1
        isRecording = false
        pendingTranscript = nil
        finishTask = nil
        hitDurationLimit = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        legacyTask?.cancel()
        await cleanup()
        partialText = ""
    }

    private func cleanup() async {
        durationLimitTask?.cancel()
        durationLimitTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
        converter = nil
        analyzerFormat = nil
        audioStateLock.withLock {
            analyzerFormatUnsafe = nil
            converterUnsafe = nil
        }
        legacyTask = nil
        legacyRequest = nil
        legacyRecognizer = nil
        level = 0
        deactivateSession()
    }

    // MARK: - Audio session

    /// Through `AudioSession` rather than straight at `AVAudioSession`, because
    /// the session is no longer this class's to own: listening to the Mac plays
    /// through it too, and deactivating it on the way out of a hold used to stop
    /// that audio dead. See `AudioSession`.
    private func configureSession() throws {
        try AudioSession.beginDictation()
    }

    private func deactivateSession() {
        AudioSession.endDictation()
    }

    // MARK: - SpeechAnalyzer path

    private func startAnalyzer(vocabulary terms: [String]) async -> Bool {
        guard SpeechTranscriber.isAvailable else {
            voiceLog.info("SpeechTranscriber unavailable on this device")
            return false
        }

        // A language somebody chose and the transcriber has no model for goes
        // to the older recognizer in that language — not to English, which is
        // what this used to fall back to whatever was being said. Only the
        // phone's own language, never chosen, keeps that fallback.
        let chosen = DictationLanguage.chosen
        let wanted = DictationLanguage.locale(for: chosen)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
            ?? (chosen.isEmpty ? Locale(identifier: "en-US") : nil) else {
            voiceLog.info("SpeechTranscriber has no model for \(wanted.identifier, privacy: .public)")
            return false
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])

        // Assets are a per-locale download managed by the system.
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            voiceLog.info("asset status for \(locale.identifier, privacy: .public): \(String(describing: status), privacy: .public)")
            if status != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                voiceLog.info("downloading speech assets…")
                try await request.downloadAndInstall()
            }
        } catch {
            voiceLog.error("asset install failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "On-device speech isn't ready for this language yet; using Apple's recognition instead"
            return false
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            voiceLog.error("no compatible analyzer audio format")
            return false
        }
        voiceLog.info("analyzer format: \(format.sampleRate, format: .fixed(precision: 0))Hz \(format.channelCount)ch")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let context = AnalysisContext()
        if !terms.isEmpty {
            context.contextualStrings[.general] = terms
            voiceLog.info("biasing transcription with \(terms.count) project terms")
        }
        // The context is installed at construction rather than set afterwards,
        // so nothing async sits between the 320ms hold threshold and the first
        // word being spoken.
        let analyzer = SpeechAnalyzer(inputSequence: stream,
                                      modules: [transcriber],
                                      analysisContext: context)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.analyzerFormat = format

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.finalizedText += (self.finalizedText.isEmpty ? "" : " ") + text
                            self.partialText = self.finalizedText
                        } else {
                            self.partialText = self.finalizedText.isEmpty
                                ? text
                                : self.finalizedText + " " + text
                        }
                    }
                }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
        }

        installTap { [weak self] buffer in
            guard let self, let converted = self.convert(buffer) else { return }
            self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
        }
        return true
    }

    /// The mic's native format rarely matches what the analyzer wants, so every
    /// buffer goes through an AVAudioConverter. (iOS 27 adds
    /// `AnalyzerInputConverter` for this; doing it by hand keeps iOS 26 working.)
    private nonisolated func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let resolved: (format: AVAudioFormat, converter: AVAudioConverter?)? = audioStateLock.withLock {
            guard let targetFormat = analyzerFormatUnsafe else { return nil }
            if buffer.format == targetFormat { return (targetFormat, nil) }
            if converterUnsafe == nil || converterUnsafe?.inputFormat != buffer.format {
                converterUnsafe = AVAudioConverter(from: buffer.format, to: targetFormat)
                converterUnsafe?.primeMethod = .none
            }
            return (targetFormat, converterUnsafe)
        }
        guard let resolved else { return nil }
        let targetFormat = resolved.format
        // Formats already match: hand the buffer straight through.
        guard let converter = resolved.converter else { return buffer }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // The audio tap runs on a real-time thread and cannot hop to the main actor
    // per buffer, so the format and converter live outside actor isolation,
    // guarded by a plain lock.
    private nonisolated(unsafe) var analyzerFormatUnsafe: AVAudioFormat?
    private nonisolated(unsafe) var converterUnsafe: AVAudioConverter?
    private let audioStateLock = NSLock()

    // MARK: - Legacy path

    private func startLegacy() -> Bool {
        voiceLog.info("using legacy SFSpeechRecognizer path")
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            errorMessage = "Speech recognition not authorized"
            return false
        }
        let chosen = DictationLanguage.chosen
        guard let recognizer = SFSpeechRecognizer(locale: DictationLanguage.locale(for: chosen))
                ?? (chosen.isEmpty ? SFSpeechRecognizer() : nil),
              recognizer.isAvailable else {
            errorMessage = chosen.isEmpty ? "Speech recognizer unavailable"
                : "Dictation in \(DictationLanguage.option(for: chosen).name) isn't available on this iPhone"
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device, but never *demand* it: the Simulator reports support
        // it doesn't have, and a forced on-device request there returns silence
        // with no error at all.
        let onDevice = recognizer.supportsOnDeviceRecognition && !Self.isSimulator
        request.requiresOnDeviceRecognition = onDevice
        voiceLog.info("legacy recognizer: locale=\(recognizer.locale.identifier, privacy: .public) onDevice=\(onDevice, privacy: .public) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")

        legacyRecognizer = recognizer
        legacyRequest = request
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    // Length only: a partial is still the user's speech, and it
                    // arrives many times per sentence, so logging the text meant
                    // a whole dictation reached the log word by word.
                    voiceLog.info("legacy partial (final=\(result.isFinal, privacy: .public)): \(result.bestTranscription.formattedString.count) chars")
                }
                if let error {
                    voiceLog.error("legacy recognizer error: \(error.localizedDescription, privacy: .public)")
                    if self.partialText.isEmpty {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }

        installTap { [weak self] buffer in
            self?.legacyRequest?.append(buffer)
        }
        return true
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: - Tap

    private func installTap(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        audioStateLock.withLock {
            analyzerFormatUnsafe = analyzerFormat
            converterUnsafe = nil
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        voiceLog.info("mic tap format: \(format.sampleRate, format: .fixed(precision: 0))Hz \(format.channelCount)ch")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            handler(buffer)
            guard let self else { return }
            let peak = Self.peakLevel(of: buffer)
            Self.logPeakOccasionally(peak)
            Task { @MainActor in self.level = peak }
        }
        audioEngine.prepare()
    }

    /// Distinguishes "the mic heard nothing" from "the recognizer dropped it".
    private nonisolated static let peakCounter = Box(0)
    private nonisolated static func logPeakOccasionally(_ peak: Float) {
        peakCounter.value += 1
        guard peakCounter.value % 20 == 0 else { return }
        voiceLog.info("mic level: \(peak, format: .fixed(precision: 3))")
    }

    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for index in stride(from: 0, to: count, by: 8) {
            peak = max(peak, abs(channel[index]))
        }
        return min(1, peak * 3)
    }
}

/// Minimal reference box so the real-time audio tap can reach a couple of
/// values without crossing an actor boundary per buffer.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
