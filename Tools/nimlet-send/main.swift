import Foundation
import Network

/// nimlet-send — a headless Nimlet client.
///
/// Exercises the host's text-delivery path (focus → paste → Return) without a
/// phone, which is how you tell a dictation problem from a delivery problem.
/// It is also just useful: pipe anything on the Mac into a chosen target.
///
///   nimlet-send --code ABC123 --text "run the tests"
///   nimlet-send --code ABC123 --target Claude --text "summarise the diff"
///   echo "hello" | nimlet-send --code ABC123
///   nimlet-send --code ABC123 --list
///   nimlet-send --code ABC123 --watch 5
///   nimlet-send --code ABC123 --listen 5

struct Options {
    var code = ""
    var text: String?
    var targetName: String?
    var list = false
    var submit: Bool?
    var benchHz: Double = 0
    var benchSeconds: Double = 5
    var watchSeconds: Double = 0
    var listenSeconds: Double = 0
    var focusName: String?
    var hostName: String?
}

func parseArguments() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--code", "-c": options.code = iterator.next() ?? ""
        case "--text", "-t": options.text = iterator.next()
        case "--target": options.targetName = iterator.next()
        case "--list", "-l": options.list = true
        case "--bench-hz": options.benchHz = Double(iterator.next() ?? "") ?? 0
        case "--bench-seconds": options.benchSeconds = Double(iterator.next() ?? "") ?? 5
        case "--watch": options.watchSeconds = Double(iterator.next() ?? "") ?? 5
        case "--listen": options.listenSeconds = Double(iterator.next() ?? "") ?? 5
        case "--focus": options.focusName = iterator.next()
        case "--host": options.hostName = iterator.next()
        case "--submit": options.submit = true
        case "--no-submit": options.submit = false
        case "--help", "-h":
            print("""
            usage: nimlet-send --code <PAIRING CODE> [options]
              -t, --text <string>   text to deliver (default: read stdin)
                  --target <name>   target name as shown on the phone
              -l, --list            list the host's targets and exit
                  --submit          force pressing Return after delivery
                  --no-submit       force not pressing Return
                  --bench-hz <n>    send pointer moves at n Hz and report send-side timing
                  --bench-seconds   how long to run the bench (default 5)
                  --watch <secs>    attach as a panel viewer and report what arrives
                  --listen <secs>   attach as a listener and report the audio arriving
                  --focus <name>    make that target active, without delivering anything
                  --host <name>     pick a Mac by Bonjour name when several are advertising

            The bench alternates +1/-1 pixel deltas, so the cursor jitters by a
            pixel but does not drift.
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

let options = parseArguments()
guard !options.code.isEmpty else {
    FileHandle.standardError.write(Data("error: --code is required (see the Nimlet menu bar item)\n".utf8))
    exit(2)
}

let payloadText: String? = {
    if let text = options.text { return text }
    if options.list || options.benchHz > 0 || options.watchSeconds > 0
        || options.listenSeconds > 0 || options.focusName != nil { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (string?.isEmpty ?? true) ? nil : string
}()

guard options.list || options.benchHz > 0 || options.watchSeconds > 0
        || options.listenSeconds > 0 || options.focusName != nil || payloadText != nil else {
    FileHandle.standardError.write(Data("error: nothing to send (use --text or pipe stdin)\n".utf8))
    exit(2)
}

/// Counts what arrives on the view channel so a run says something checkable.
struct ViewStats {
    var frames = 0
    var keyframes = 0
    var bytes = 0
    var kinds: [String: Int] = [:]
    var title = ""
    var lastState: String?
    var geometry: String?
    var sample: [String] = []
    private var started = Date()

    mutating func record(_ frame: ViewFrame, payload: Data) {
        frames += 1
        bytes += payload.count
        kinds[frame.kind.rawValue, default: 0] += 1
        if frame.isKeyframe == true { keyframes += 1 }
        if !frame.title.isEmpty { title = frame.title }

        switch frame.kind {
        case .state:
            lastState = frame.reason
        case .video:
            geometry = "\(frame.width ?? 0)x\(frame.height ?? 0) \(frame.codec?.rawValue ?? "?")"
        case .text:
            geometry = "\(frame.columns ?? 0)x\(frame.rows ?? 0) chars"
            if sample.isEmpty, let text = String(data: payload, encoding: .utf8) {
                sample = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(3)
                    .map { String($0).replacingOccurrences(of: "\u{1B}", with: "\\e") }
            }
        }
    }

    func report() {
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        print("title:    \(title.isEmpty ? "—" : title)")
        print("frames:   \(frames) (\(kinds.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")))")
        print("rate:     \(String(format: "%.1f", Double(frames) / elapsed)) fps, \(String(format: "%.1f", Double(bytes) / elapsed / 1024)) KB/s")
        if keyframes > 0 { print("keyframes: \(keyframes)") }
        if let geometry { print("geometry: \(geometry)") }
        if let lastState { print("state:    \(lastState)") }
        for line in sample { print("  | \(line.prefix(100))") }
        if frames == 0 { print("nothing arrived — is a target selected on the Mac?") }
    }
}

/// Counts what arrives on the listen channel, and decodes it, so a run says
/// something checkable about audio nobody can hear from here.
///
/// The peak is the point. "Frames are arriving" and "the Mac is sending silence"
/// look identical from every other vantage point — including from a phone in
/// another room, which is where this is hardest to tell — so this decodes the
/// AAC back to samples and reports how loud they were.
struct ListenStats {
    var frames = 0
    var packets = 0
    var bytes = 0
    var decodedFrames = 0
    var peak: Float = 0
    var sumSquares = 0.0
    var format: String?
    var lastState: String?
    var gaps = 0
    private var lastSequence: UInt32?
    private var decoder = AudioDecoder()
    private var started = Date()

    mutating func record(_ frame: AudioFrame, payload: Data) {
        switch frame.kind {
        case .state:
            lastState = frame.reason
            return
        case .audio:
            break
        }
        frames += 1
        bytes += payload.count
        if let sequence = frame.sequence {
            if let last = lastSequence, sequence != last &+ 1 { gaps += 1 }
            lastSequence = sequence
        }
        if let rate = frame.sampleRate, let channels = frame.channels {
            format = "\(rate)Hz \(channels)ch \(frame.codec?.rawValue ?? "?")"
        }
        guard decoder.adopt(frame), let ranges = frame.packetRanges(in: payload) else { return }
        packets += ranges.count
        for range in ranges {
            guard let pcm = decoder.decode(payload.subdata(in: range)) else { continue }
            decodedFrames += Int(pcm.frameLength)
            guard let channel = pcm.floatChannelData?[0] else { continue }
            for index in 0..<Int(pcm.frameLength) {
                let sample = channel[index]
                peak = max(peak, abs(sample))
                sumSquares += Double(sample * sample)
            }
        }
    }

    func report() {
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        let rms = decodedFrames > 0 ? (sumSquares / Double(decodedFrames)).squareRoot() : 0
        print("format:   \(format ?? "—")")
        print("frames:   \(frames) in \(String(format: "%.1f", elapsed))s, \(packets) packets")
        print("rate:     \(String(format: "%.1f", Double(bytes) * 8 / elapsed / 1000)) kbps payload")
        print("audio:    \(String(format: "%.2f", Double(decodedFrames) / Double(AudioChannel.sampleRate)))s decoded, peak \(String(format: "%.4f", peak)), rms \(String(format: "%.5f", rms))")
        if gaps > 0 { print("gaps:     \(gaps) (the Mac skipped frames under back-pressure)") }
        if let lastState { print("state:    \(lastState)") }
        if frames == 0 { print("nothing arrived — is \"Let phones listen\" on, and this device approved?") }
        if peak == 0 && frames > 0 { print("arriving, but silent — nothing is playing on the Mac") }
    }
}

final class Runner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nimlet-send")
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var framer = LineFramer()
    private var viewReader = ViewFrameReader()
    private var viewStats = ViewStats()
    private var audioReader = AudioFrameReader()
    private var listenStats = ListenStats()
    private var didSend = false
    private let done = DispatchSemaphore(value: 0)
    private var exitCode: Int32 = 1

    func run() -> Int32 {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NimletProtocol.bonjourType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }
            // With several Macs advertising, "the first one Bonjour mentions" is
            // a coin toss, so let the caller name the one it means.
            let match = results.first { result in
                guard let wanted = options.hostName else { return true }
                guard case let .service(name, _, _, _) = result.endpoint else { return false }
                return name.localizedCaseInsensitiveContains(wanted)
            }
            guard let match else { return }
            self.connect(to: match.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser

        let secondsAsked = max(options.watchSeconds, options.listenSeconds)
        let budget: Double = options.benchHz > 0
            ? options.benchSeconds + 15
            : (secondsAsked > 0 ? secondsAsked + 15 : 15)
        if done.wait(timeout: .now() + budget) == .timedOut {
            FileHandle.standardError.write(Data("error: timed out finding or talking to a Nimlet host\n".utf8))
            exitCode = 1
        }
        browser.cancel()
        connection?.cancel()
        return exitCode
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: NimletTransport.parameters(pairingCode: options.code))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard options.watchSeconds == 0 else { self.startWatching(); return }
                guard options.listenSeconds == 0 else { self.startListening(); return }
                self.send(.hello(HelloPayload(deviceName: "nimlet-send", deviceID: Self.deviceID)))
            case .failed(let error):
                FileHandle.standardError.write(Data("error: \(error.localizedDescription) (wrong pairing code?)\n".utf8))
                self.exitCode = 1
                self.done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if options.watchSeconds > 0 {
                    for frame in self.viewReader.append(data) {
                        self.viewStats.record(frame.frame, payload: frame.payload)
                    }
                } else if options.listenSeconds > 0 {
                    for frame in self.audioReader.append(data) {
                        self.listenStats.record(frame.frame, payload: frame.payload)
                    }
                } else {
                    for line in self.framer.append(data) { self.handle(line) }
                }
            }
            if isComplete || error != nil { self.done.signal(); return }
            self.receive()
        }
    }

    /// One spelling of "which target did they mean", so `--focus Claude` and
    /// `--target Claude` cannot drift apart. Reports and exits on a miss.
    private func resolveTarget(named name: String, in targets: [NimletTarget]) -> NimletTarget? {
        if let match = targets.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return match
        }
        FileHandle.standardError.write(Data("error: no target named \(name)\n".utf8))
        exitCode = 2
        done.signal()
        return nil
    }

    /// Attaches as a panel viewer and reports what the host actually sends.
    /// The video path needs no phone to exercise, and "is anything arriving at
    /// all" is the first question when a mirror looks blank.
    /// The id this tool identifies as. Named once, because the listen and panel
    /// channels are refused for a device the Mac has not approved — which is the
    /// first thing to check when one of these runs reports nothing at all.
    static let deviceID = "nimlet-send:diagnostics"

    /// Attaches as a listener and reports what the host actually sends.
    ///
    /// The audio path needs no phone to exercise, and "is anything arriving, and
    /// is it silence" are the two questions when somebody in another room cannot
    /// hear their Mac — neither of which can be answered from the phone, because
    /// the phone is the thing that is quiet.
    private func startListening() {
        let hello = ListenHelloPayload(deviceName: "nimlet-send", deviceID: Self.deviceID)
        guard let data = try? NimletCoder.line(ClientMessage.listenHello(hello)) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
        print("listening for \(Int(options.listenSeconds))s…")
        queue.asyncAfter(deadline: .now() + options.listenSeconds) { [weak self] in
            guard let self else { return }
            self.listenStats.report()
            self.exitCode = self.listenStats.frames > 0 ? 0 : 1
            self.done.signal()
        }
    }

    private func startWatching() {
        let hello = ViewHelloPayload(deviceName: "nimlet-send", deviceID: Self.deviceID,
                                     maxWidth: 1179, maxHeight: 2556)
        guard let data = try? NimletCoder.line(ClientMessage.viewHello(hello)) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
        print("watching for \(Int(options.watchSeconds))s…")
        queue.asyncAfter(deadline: .now() + options.watchSeconds) { [weak self] in
            guard let self else { return }
            self.viewStats.report()
            self.exitCode = self.viewStats.frames > 0 ? 0 : 1
            self.done.signal()
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? NimletCoder.decode(HostMessage.self, from: line) else { return }
        switch message {
        case .welcome(let status, let targets):
            if options.benchHz > 0 {
                guard !didSend else { return }
                didSend = true
                runBench()
                return
            }
            if options.list {
                print("host: \(status.hostName)")
                print("accessibility: \(status.accessibilityGranted ? "granted" : "NOT GRANTED — clicks and typing will be ignored")")
                print("injection: \(status.injectionPaused ? "paused" : "active")")
                print("targets:")
                for target in targets {
                    let detail = target.bundleID ?? target.tmuxTarget ?? "—"
                    let active = target.id == status.activeTargetID ? " *" : ""
                    print("  \(target.name)  [\(target.kind.rawValue)] \(detail)\(active)")
                }
                exitCode = 0
                done.signal()
                return
            }
            if let name = options.focusName {
                guard !didSend else { return }
                didSend = true
                guard let match = resolveTarget(named: name, in: targets) else { return }
                send(.focus(targetID: match.id))
                return
            }

            guard !didSend, let text = payloadText else { return }
            didSend = true

            var targetID: String?
            if let name = options.targetName {
                guard let match = resolveTarget(named: name, in: targets) else { return }
                targetID = match.id
            }
            send(.text(TextPayload(text: text, targetID: targetID, submit: options.submit)))

        case .toast(let text):
            print(text)
            exitCode = 0
            done.signal()

        case .error(let text):
            FileHandle.standardError.write(Data("error: \(text)\n".utf8))
            exitCode = 1
            done.signal()

        default:
            break
        }
    }

    private func send(_ message: ClientMessage) {
        guard let data = try? NimletCoder.line(message) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Drives the host at a fixed rate and reports how regular the *sending*
    /// was, so host-side jitter can be separated from client-side jitter.
    private func runBench() {
        let interval = 1.0 / options.benchHz
        let total = Int(options.benchSeconds * options.benchHz)
        var sendDurations: [Double] = []
        var wakeErrors: [Double] = []
        let start = DispatchTime.now().uptimeNanoseconds
        var sign = 1.0

        for index in 0..<total {
            let due = start &+ UInt64(Double(index) * interval * 1_000_000_000)
            var now = DispatchTime.now().uptimeNanoseconds
            if due > now {
                Thread.sleep(forTimeInterval: Double(due &- now) / 1_000_000_000)
                now = DispatchTime.now().uptimeNanoseconds
            }
            wakeErrors.append(Double(now &- due) / 1_000_000)

            let sendStart = DispatchTime.now().uptimeNanoseconds
            // Alternating sign keeps the cursor from walking off the screen.
            send(.move(dx: sign, dy: 0))
            sign = -sign
            sendDurations.append(Double(DispatchTime.now().uptimeNanoseconds &- sendStart) / 1000)
        }

        func summarise(_ label: String, _ values: [Double], _ unit: String) {
            guard !values.isEmpty else { return }
            let sorted = values.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            print(String(format: "  %-16s n=%d mean=%.1f%@ p50=%.1f%@ p95=%.1f%@ max=%.1f%@",
                         (label as NSString).utf8String!, sorted.count,
                         mean, unit, p50, unit, p95, unit, sorted[sorted.count - 1], unit))
        }

        print("bench: \(total) moves at \(Int(options.benchHz)) Hz over \(options.benchSeconds)s")
        summarise("send_call", sendDurations, "us")
        summarise("wake_error", wakeErrors, "ms")

        // Let the last packets drain before tearing the connection down.
        Thread.sleep(forTimeInterval: 0.3)
        exitCode = 0
        done.signal()
    }
}

// Held in a global so the callbacks' `weak self` stays alive for the run.
let runner = Runner()
exit(runner.run())
