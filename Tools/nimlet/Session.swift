import Foundation
import Network

/// One connection to a Nimlet host, with a blocking API.
///
/// Network.framework is callback-driven and the tool is a straight line —
/// connect, say one thing, report what came back — so inbound messages are
/// parked in a queue that the calling thread waits on, rather than the whole
/// tool being written inside out around the callbacks.
final class Session: @unchecked Sendable {
    private let config: Config
    private let timeout: Double
    private let queue = DispatchQueue(label: "com.renyicao.mice.cli.net")
    private var browser: NWBrowser?
    private var framer = LineFramer()

    private let condition = NSCondition()
    private var inbox: [HostMessage] = []
    private var connection: NWConnection?
    private var discovered: [String] = []
    private var dialing: String?
    /// True once the TLS handshake has completed, which is the only proof the
    /// pairing code was right.
    private var isConnected = false
    /// Why the connection is still not up, when the stack is retrying rather
    /// than giving up. Only ever used to explain a timeout.
    private var stalledOn: String?
    private var failure: CLIError?
    private var isClosed = false

    init(config: Config, timeout: Double) {
        self.config = config
        self.timeout = timeout
    }

    // MARK: - Lifecycle

    /// Finds the Mac, connects, and returns its introduction.
    func connect() throws -> (status: HostStatus, targets: [NimletTarget]) {
        let deadline = Date().addingTimeInterval(timeout)
        startBrowsing()

        let introduction = try receive(deadline: deadline) { message in
            if case .welcome = message { return true }
            return false
        }
        guard case .welcome(let status, let targets) = introduction else {
            throw CLIError(.unreachable, "the host did not introduce itself")
        }

        // `welcome` goes out as soon as the socket is ready, which is before the
        // host has read our hello and therefore before it knows which device we
        // are. Two things follow from that, and both arrive afterwards: its
        // `deviceApproved` is not yet about us, and it carries no targets —
        // the target list names every project, app and pane the user works in,
        // so the host withholds it until it knows who is asking and the user
        // has approved them. Collect both before giving up.
        var settledStatus = status
        var settledTargets = targets
        var sawStatus = false
        var sawTargets = !targets.isEmpty
        let settleBy = Date().addingTimeInterval(1.0)

        while !(sawStatus && sawTargets), Date() < settleBy {
            do {
                let message = try receive(deadline: settleBy) {
                    switch $0 {
                    case .status, .targets: return true
                    default: return false
                    }
                }
                switch message {
                case .status(let fresh):
                    settledStatus = fresh
                    sawStatus = true
                    // An unapproved device is never sent targets, so waiting for
                    // them would only burn the timeout before the refusal the
                    // caller needs to print.
                    if !fresh.deviceApproved { sawTargets = true }
                case .targets(let fresh):
                    settledTargets = fresh
                    sawTargets = true
                default:
                    break
                }
            } catch let error as CLIError where error.code == .timedOut {
                // A host a release behind sends neither after the hello.
                break
            }
        }
        return (settledStatus, settledTargets)
    }

    func close() {
        browser?.cancel()
        browser = nil
        currentConnection()?.cancel()
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NimletProtocol.bonjourType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.pick(from: results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            self?.fail(CLIError(.unreachable, "could not browse for hosts: \(error.localizedDescription)"))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func pick(from results: Set<NWBrowser.Result>) {
        guard currentConnection() == nil else { return }

        // Bonjour reports the same service once per interface (en0, awdl0,
        // utun...), so taking the first result picked an arbitrary interface and
        // could dial one that is down. Collapse by service name and let
        // Network.framework choose the route.
        var seen = Set<String>()
        var hosts: [(name: String, endpoint: NWEndpoint)] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard seen.insert(name).inserted else { continue }
            hosts.append((name, result.endpoint))
        }
        hosts.sort { $0.name < $1.name }

        condition.lock()
        discovered = hosts.map(\.name)
        condition.unlock()

        if let wanted = config.hostName {
            guard let match = hosts.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                return
            }
            dial(match.name, match.endpoint)
            return
        }
        if hosts.count > 1 {
            let names = hosts.map(\.name).joined(separator: ", ")
            fail(CLIError(.unreachable, "several Macs are advertising Nimlet (\(names)) — pick one with `nimlet pair --host NAME`"))
            return
        }
        guard let only = hosts.first else { return }
        dial(only.name, only.endpoint)
    }

    // MARK: - Connection

    private func dial(_ name: String, _ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint,
                                      using: NimletTransport.parameters(pairingCode: config.pairingCode))
        condition.lock()
        self.connection = connection
        dialing = name
        condition.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.handshook()
                self.send(.hello(HelloPayload(deviceName: Config.deviceName, deviceID: self.config.deviceID)))
            case .waiting(let error):
                // Keep it only to explain a timeout with. The stack is still
                // retrying, and a CLI that gave up on the first waiting state
                // would fail on an interface that comes up a moment late.
                self.note(waiting: error)
            case .failed(let error):
                self.fail(CLIError(.unreachable, Session.explain(error, host: name)))
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    /// A TLS error at this point means the two ends disagreed about the key, so
    /// say that rather than printing a raw handshake failure. A key the host
    /// rejects outright more often hangs instead of failing, which is why
    /// `timedOut` has to make the same point again.
    private static func explain(_ error: NWError, host: String) -> String {
        if case .tls = error { return "\(host) rejected the pairing code" }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("handshake") { return "\(host) rejected the pairing code" }
        return "\(host): \(text)"
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var messages: [HostMessage] = []
                for line in self.framer.append(data) {
                    guard let message = try? NimletCoder.decode(HostMessage.self, from: line) else { continue }
                    messages.append(message)
                }
                if !messages.isEmpty { self.deliver(messages) }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    // MARK: - Inbox

    private func deliver(_ messages: [HostMessage]) {
        condition.lock()
        inbox.append(contentsOf: messages)
        condition.broadcast()
        condition.unlock()
    }

    private func fail(_ error: CLIError) {
        condition.lock()
        if failure == nil { failure = error }
        condition.broadcast()
        condition.unlock()
    }

    private func finish() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    private func note(waiting error: NWError) {
        condition.lock()
        stalledOn = error.localizedDescription
        condition.unlock()
    }

    private func handshook() {
        condition.lock()
        isConnected = true
        condition.unlock()
    }

    private func currentConnection() -> NWConnection? {
        condition.lock()
        defer { condition.unlock() }
        return connection
    }

    /// Waits for the first message the predicate accepts. A host `error` that
    /// the predicate does not want ends the wait too: it is the host telling us
    /// why the thing we asked for is not going to happen.
    @discardableResult
    func receive(within seconds: Double? = nil,
                 where matches: (HostMessage) -> Bool) throws -> HostMessage {
        try receive(deadline: Date().addingTimeInterval(seconds ?? timeout), where: matches)
    }

    private func receive(deadline: Date, where matches: (HostMessage) -> Bool) throws -> HostMessage {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = inbox.firstIndex(where: matches) {
                return inbox.remove(at: index)
            }
            for message in inbox {
                if case .error(let text) = message { throw CLIError(.refused, text) }
            }
            // Nothing here is what this call is waiting for, and no later call
            // will want it either: the tool asks one question per run.
            inbox.removeAll()
            if let failure { throw failure }
            if isClosed { throw CLIError(.unreachable, "the host closed the connection") }
            if !condition.wait(until: deadline) { throw timedOut() }
        }
    }

    /// Waits out a short window purely to catch a refusal, for messages the host
    /// does not acknowledge.
    func drain(seconds: Double) throws {
        do {
            _ = try receive(deadline: Date().addingTimeInterval(seconds)) { _ in false }
        } catch let error as CLIError where error.code == .timedOut {
            return
        }
    }

    private func timedOut() -> CLIError {
        let budget = String(format: "%.0f", timeout)
        if let dialing {
            guard isConnected else {
                // A host that rejects the pre-shared key does not refuse the
                // connection — it leaves it in `preparing` and says nothing, so
                // a wrong code and a sleeping Mac look identical from here.
                // Guessing "sleeping Mac" is the expensive guess: it sends
                // people off re-typing a code that was right all along.
                let suffix = stalledOn.map { ": \($0)" } ?? ""
                return CLIError(.unreachable,
                                "\(dialing) never completed the handshake in \(budget)s\(suffix)"
                                    + " — wrong pairing code?")
            }
            return CLIError(.timedOut, "\(dialing) did not reply within \(budget)s")
        }
        if discovered.isEmpty {
            return CLIError(.unreachable, "no Mac is advertising Nimlet on this network — is the menu bar app running?")
        }
        if let wanted = config.hostName {
            return CLIError(.unreachable, "no Mac called \(wanted) — found: \(discovered.joined(separator: ", "))")
        }
        return CLIError(.unreachable, "found \(discovered.joined(separator: ", ")) but could not connect within \(budget)s")
    }

    // MARK: - Sending

    func send(_ message: ClientMessage) {
        guard let data = try? NimletCoder.line(message) else { return }
        currentConnection()?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Returns once the bytes have reached the network stack, so a command that
    /// expects no reply cannot exit before its message leaves the machine.
    func sendAndFlush(_ message: ClientMessage) throws {
        guard let data = try? NimletCoder.line(message) else {
            throw CLIError(.usage, "could not encode that message")
        }
        guard let connection = currentConnection() else {
            throw CLIError(.unreachable, "not connected")
        }
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in sent.signal() })
        guard sent.wait(timeout: .now() + timeout) == .success else {
            throw CLIError(.timedOut, "the message was never sent")
        }
    }
}
