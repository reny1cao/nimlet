import XCTest
import StoreKit
import StoreKitTest
import Network
import AVFoundation
import OSLog
import CryptoKit
import SwiftUI

let miceLog = Logger(subsystem: "com.renyicao.mice.tests", category: "audio")

/// A Mac's side of pairing, as small as it can be: the keys it accepts and
/// the one invitation it has open.
private final class TrustedMac: @unchecked Sendable {
    let identity = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    let secret = PairingProof.newSecret()
    private let lock = NSLock()
    private var approved: Set<TrustFingerprint> = []
    private var pairingOpen = true
    var approvedKeys: Set<TrustFingerprint> { lock.withLock { approved } }
    func accepts(_ key: TrustFingerprint) -> Bool { lock.withLock { approved.contains(key) || pairingOpen } }
    func approve(_ key: TrustFingerprint) { lock.withLock { approved.insert(key); pairingOpen = false } }
    func revokeAll() { lock.withLock { approved.removeAll(); pairingOpen = false } }

    /// Verifies a proof against this connection's own exporter and key.
    func check(_ request: PairRequest, on connection: NWConnection) -> Bool {
        guard let peer = TrustTransport.peerFingerprint(of: connection),
              let exporter = TrustTransport.exporter(of: connection, label: PairingProof.exporterLabel),
              PairingProof.verify(request.proof, secret: secret, exporter: exporter, device: peer) else { return false }
        approve(peer)
        return true
    }
}

/// Real TLS 1.3 sockets with pinned keys, and the production client. The
/// fixture has no injection or device registry and cannot control the user's
/// Mac.
private final class TestMac: @unchecked Sendable {
    let listener: NWListener
    let trust: TrustedMac
    let queue = DispatchQueue(label: "mice.connection.tests")
    var connections: [NWConnection] = []
    var onHello: ((NWConnection) -> Void)?
    var onMessage: ((NWConnection, ClientMessage) -> Void)?
    var respondsToPing: ((NWConnection) -> Bool)?
    var onViewHello: ((NWConnection) -> Void)?
    var shouldStartConnection: ((NWConnection) -> Bool)?
    private let viewLock = NSLock()
    private var recordedViewHellos: [ViewHelloPayload] = []
    private var latestViewConnection: NWConnection?
    var viewHellos: [ViewHelloPayload] { viewLock.withLock { recordedViewHellos } }

    /// Layout metadata only. These fixtures do not claim decoded video.
    func sendViewGeometry(width: Int, height: Int) {
        guard let connection = viewLock.withLock({ latestViewConnection }) else { return }
        var frame = ViewFrame(kind: .video, title: "Constrained window", captureTime: Instrumentation.now())
        frame.width = width; frame.height = height
        let data = try! ViewFrameWriter.encode(frame, payload: Data())
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    var onListenHello: ((NWConnection, ListenHelloPayload) -> Void)?
    var onPair: ((NWConnection, PairRequest) -> Void)?
    var hellos = 0
    var pairs = 0

    /// - Parameter paired: whether this phone's key is already approved, as it
    ///   is for every test that is not about pairing itself.
    @MainActor init(paired: Bool = true) throws {
        let trust = TrustedMac()
        self.trust = trust
        listener = try NWListener(using: TrustTransport.parameters(identity: trust.identity,
                                                                   accepts: { trust.accepts($0) },
                                                                   peerToPeer: false), on: .any)
        if paired, let phone = PhoneTrust.identity?.fingerprint { trust.approve(phone) }
        onPair = { [unowned self] connection, request in
            let ok = trust.check(request, on: connection)
            self.send(.pairResult(PairResult(ok: ok, message: ok ? nil : "That code was not this Mac's")),
                      on: connection, close: !ok)
        }
        onHello = { [unowned self] in self.welcome($0) }
    }

    var port: UInt16 { listener.port!.rawValue }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                guard self.shouldStartConnection?(connection) != false else { return }
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, framer: LineFramer = LineFramer()) {
        var framer = framer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            for line in data.map({ framer.append($0) }) ?? [] {
                guard let message = try? NimletCoder.decode(ClientMessage.self, from: line) else { continue }
                self.onMessage?(connection, message)
                switch message {
                case .hello:
                    self.hellos += 1
                    self.onHello?(connection)
                case .viewHello(let hello):
                    self.viewLock.withLock {
                        self.recordedViewHellos.append(hello)
                        self.latestViewConnection = connection
                    }
                    self.onViewHello?(connection)
                case .listenHello(let hello):
                    self.onListenHello?(connection, hello)
                case .pair(let request):
                    self.pairs += 1
                    self.onPair?(connection, request)
                case .ping(let nonce):
                    if self.respondsToPing?(connection) != false {
                        self.send(.pong(nonce: nonce, hostTime: Instrumentation.now()), on: connection)
                    }
                default: break
                }
            }
            if !done && error == nil { self.receive(connection, framer: framer) }
        }
    }

    func send(_ message: HostMessage, on connection: NWConnection, close: Bool = false) {
        connection.send(content: try! NimletCoder.line(message), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    func welcome(_ connection: NWConnection) {
        send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                                        injectionPaused: false, activeTargetID: nil, deviceApproved: true),
                      targets: []), on: connection)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.listener.cancel()
                self.connections.forEach { $0.cancel() }
                self.onHello = nil
                self.onMessage = nil
                self.respondsToPing = nil
                self.onViewHello = nil
                self.viewLock.withLock { self.latestViewConnection = nil }
                self.onListenHello = nil
                self.onPair = nil
                continuation.resume()
            }
        }
    }
}

@MainActor
final class ConnectionTests: XCTestCase {
    func testDockRunningStateTracksProcessesWithoutWeakeningWindowIdentity() async throws {
        let mac = try TestMac()
        let legacy = AppReference(bundleID: "org.nimlet.RunningQA")
        let firstCopy = AppReference(bundleID: legacy.bundleID, applicationPath: "/Applications/RunningQA.app")
        let secondCopy = AppReference(bundleID: legacy.bundleID, applicationPath: "/Users/me/RunningQA.app")
        let otherCopy = AppReference(bundleID: legacy.bundleID, applicationPath: "/Users/me/Other/RunningQA.app")
        let snapshot = AppRuntimeSnapshot(hostSessionID: "running-fixture", revision: 7, apps: [
            RunningMacApp(identity: AppInstanceIdentity(hostSessionID: "running-fixture", instanceID: "first", processID: 42, app: firstCopy),
                          name: "Running QA", isActive: false, isHidden: true),
            RunningMacApp(identity: AppInstanceIdentity(hostSessionID: "running-fixture", instanceID: "second", processID: 43, app: secondCopy),
                          name: "Running QA", isActive: false, isHidden: false)
        ])
        mac.onHello = { connection in
            mac.send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                injectionPaused: false, activeTargetID: nil, deviceApproved: true, appManagementVersion: 1), targets: []), on: connection)
        }
        mac.onMessage = { connection, message in
            if case .requestAppState = message { mac.send(.appState(snapshot), on: connection) }
        }
        try await mac.start()
        let client = makeClient()
        XCTAssertEqual(client.appRunningState(for: legacy), .unknown)
        let host = pairedHost(mac)
        client.connect(to: host)
        let ready = await waitUntil { client.appRuntime != nil }
        XCTAssertTrue(ready)
        XCTAssertNil(client.runningApp(for: legacy), "window/quit operations must still require a unique process")
        XCTAssertEqual(client.appRunningState(for: legacy), .running, "multiple processes must not make the running dot disappear")
        XCTAssertEqual(client.appRunningState(for: firstCopy), .running, "hidden or unfocused apps are still running")
        XCTAssertEqual(client.appRunningState(for: otherCopy), .notRunning, "another installed copy must not inherit a running dot")
        let stopped = AppRuntimeSnapshot(hostSessionID: snapshot.hostSessionID, revision: 8, apps: [])
        mac.queue.async { for connection in mac.connections { mac.send(.appState(stopped), on: connection) } }
        let updated = await waitUntil { client.appRunningState(for: legacy) == .notRunning }
        XCTAssertTrue(updated, "the host's exit update must clear the running dot")
        mac.queue.async { for connection in mac.connections { mac.send(.appState(snapshot), on: connection) } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.appRunningState(for: legacy), .notRunning, "a stale snapshot cannot revive a stopped app")
        client.disconnect()
        XCTAssertEqual(client.appRunningState(for: legacy), .unknown, "disconnect must not claim apps stopped")
        client.connect(to: host)
        let resumed = await waitUntil { client.appRunningState(for: legacy) == .running }
        XCTAssertTrue(resumed, "reconnect must use the new session's live state")
        client.disconnect(); client.forget(host); await mac.stop()
    }

    func testPhoneDockRemovalAndOrderPersistPerMacWithoutQuitting() async throws {
        let preferenceKey = "mice.dock.arrangements"
        let oldPreference = UserDefaults.standard.object(forKey: preferenceKey)
        defer {
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
        }
        let mac = try TestMac()
        let otherMac = try TestMac()
        let a = NimletTarget(id: "dock-a", name: "A", kind: .app, bundleID: "org.nimlet.A")
        let b = NimletTarget(id: "dock-b", name: "B", kind: .app, bundleID: "org.nimlet.B")
        let terminal = NimletTarget(id: "cat", name: "cat (mice)", kind: .tmux)
        let removed = expectation(description: "Mac receives only unkeep, not quit or close")
        let appCommands = AppCommandRecording()
        let snapshot = AppRuntimeSnapshot(hostSessionID: "dock-fixture", revision: 1, apps: [])
        let welcome: (TestMac, NWConnection) -> Void = { server, connection in
            server.send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                injectionPaused: false, activeTargetID: a.id, deviceApproved: true, appManagementVersion: 1), targets: [a, b, terminal]), on: connection)
            server.send(.appState(snapshot), on: connection)
        }
        mac.onHello = { welcome(mac, $0) }
        otherMac.onHello = { welcome(otherMac, $0) }
        mac.onMessage = { connection, message in
            switch message {
            case .requestAppState: mac.send(.appState(snapshot), on: connection)
            case .appCommand(let command):
                appCommands.append(command)
                XCTAssertEqual(command.action, .unkeep)
                XCTAssertEqual(command.targetID, a.id)
                let live = NimletTarget(id: "running-a", name: "A", kind: .app, bundleID: a.bundleID,
                    applicationPath: "/Applications/A.app", isProvisional: true)
                mac.send(.targets([b, live, terminal]), on: connection)
                mac.send(.appCommandResult(AppCommandResult(requestID: command.id, phase: .succeeded, message: "Removed")), on: connection)
                removed.fulfill()
            default: break
            }
        }
        try await mac.start(); try await otherMac.start()
        let (client, host) = await connectedClient(to: mac)
        let ready = await waitUntil { client.canManageApps }
        XCTAssertTrue(ready)
        XCTAssertEqual(client.dockTargets.map(\.id), [a.id, b.id])
        client.reorderDockTargets([b.id, a.id])
        XCTAssertEqual(client.dockTargets.map(\.id), [b.id, a.id])
        // An incomplete drag payload must not silently lose another tile.
        client.reorderDockTargets([a.id])
        XCTAssertEqual(client.dockTargets.map(\.id), [b.id, a.id])
        client.removeFromDock(a)
        await fulfillment(of: [removed], timeout: 5)
        let refreshed = await waitUntil { client.targets.contains { $0.id == "running-a" } }
        XCTAssertTrue(refreshed)
        let completed = await waitUntil { client.appOperation?.phase == .succeeded }
        XCTAssertTrue(completed)
        XCTAssertEqual(client.dockTargets.map(\.id), [b.id])
        XCTAssertEqual(appCommands.count, 1, "Dock removal must send only unkeep")
        XCTAssertNil(client.appOperationNotice, "normal Dock edits must not add a success banner")
        client.disconnect()
        let restarted = makeClient()
        restarted.connect(to: host)
        let reconnected = await waitUntil { restarted.state.isConnected }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(restarted.dockTargets.map(\.id), [b.id])
        let otherHost = pairedHost(otherMac)
        restarted.connect(to: otherHost)
        let switched = await waitUntil { restarted.state.isConnected && restarted.targets.count == 3 }
        XCTAssertTrue(switched)
        XCTAssertEqual(restarted.dockTargets.map(\.id), [a.id, b.id], "one Mac's Dock must not hide another Mac's app")
        restarted.disconnect(); restarted.forget(otherHost); restarted.forget(host)
        await mac.stop(); await otherMac.stop()
    }

    func testSuccessfulAppActionClearsNoticeAndAllowsNextActionDespiteLateProgress() async throws {
        let mac = try TestMac()
        let ref = AppReference(bundleID: "org.nimlet.QA", applicationPath: "/Applications/QA.app")
        let snapshot = AppRuntimeSnapshot(hostSessionID: "fixture", revision: 1, apps: [])
        let recorded = AppCommandRecording()
        mac.onHello = { connection in
            mac.send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                injectionPaused: false, activeTargetID: nil, deviceApproved: true, appManagementVersion: 1), targets: []), on: connection)
        }
        mac.onMessage = { connection, message in
            switch message {
            case .requestAppState: mac.send(.appState(snapshot), on: connection)
            case .appCommand(let command):
                recorded.append(command)
                let phase: AppCommandResult.Phase = command.action == .keep ? .failed : .succeeded
                mac.send(.appCommandResult(AppCommandResult(requestID: command.id, phase: phase, message: "result")), on: connection)
                mac.send(.appCommandResult(AppCommandResult(requestID: command.id, phase: .working, message: "late progress")), on: connection)
            default: break
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let ready = await waitUntil { client.canManageApps }; XCTAssertTrue(ready)
        XCTAssertTrue(client.performAppAction(.activate, app: ref))
        let opened = await waitUntil { client.appOperation?.phase == .succeeded }; XCTAssertTrue(opened)
        XCTAssertNil(client.appOperationNotice, "success must leave no banner in the control surface")
        XCTAssertTrue(client.performAppAction(.keep, app: ref), "a completed receipt cannot block the next action")
        let failed = await waitUntil { client.appOperation?.phase == .failed }; XCTAssertTrue(failed)
        XCTAssertNil(client.appOperationNotice, "a failed receipt must not occupy a permanent status row")
        XCTAssertEqual(client.toast, "result", "failure feedback remains visible briefly")
        let expired = await waitUntil { client.toast == nil }; XCTAssertTrue(expired)
        XCTAssertEqual(client.appOperation?.phase, .failed, "receipt retention is independent of toast expiry")
        XCTAssertTrue(client.performAppAction(.keep, app: ref))
        let failedAgain = await waitUntil { client.appOperation?.phase == .failed && client.toast != nil }; XCTAssertTrue(failedAgain)
        XCTAssertTrue(client.performAppAction(.activate, app: ref))
        XCTAssertNil(client.toast, "a new action immediately clears the previous failure")
        let reopened = await waitUntil { recorded.count == 4 && client.appOperation?.phase == .succeeded }; XCTAssertTrue(reopened)
        XCTAssertNil(client.appOperationNotice)
        client.disconnect(); client.forget(host); await mac.stop()
    }

    func testAppDirectoryAndDisconnectedCloseAreNotReplayed() async throws {
        let mac = try TestMac()
        let ref = AppReference(bundleID: "org.nimlet.QA", applicationPath: "/Applications/QA.app")
        let identity = AppInstanceIdentity(hostSessionID: "fixture", instanceID: "process", processID: 42, app: ref)
        let snapshot = AppRuntimeSnapshot(hostSessionID: "fixture", revision: 7, apps: [
            RunningMacApp(identity: identity, name: "QA", isActive: true, isHidden: false)])
        let recorded = AppCommandRecording()
        mac.onHello = { connection in
            mac.send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                injectionPaused: false, activeTargetID: nil, deviceApproved: true, appManagementVersion: 1), targets: []), on: connection)
        }
        mac.onMessage = { connection, message in
            switch message {
            case .requestAppState: mac.send(.appState(snapshot), on: connection)
            case .requestAppDirectory:
                let apps = (0..<65).map { MacApp(bundleID: "qa.\($0)", name: "App \($0)", applicationPath: "/Applications/QA\($0).app") }
                for chunk in AppCatalogPayload.chunked(apps, purpose: .suggestions) { mac.send(.apps(chunk), on: connection) }
            case .appCommand(let command):
                recorded.append(command)
                mac.send(.appCommandResult(AppCommandResult(requestID: command.id, phase: .working, message: "pending")), on: connection)
                // Deliberately lose the final result, as a broken transport would.
            default: break
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let ready = await waitUntil { client.canManageApps }; XCTAssertTrue(ready)
        client.requestApps()
        let directory = await waitUntil { !client.isFetchingApps && client.appSuggestions.count == 65 }; XCTAssertTrue(directory)
        XCTAssertTrue(client.performAppAction(.closeWindow, app: ref, identity: identity, windowID: 99))
        let arrived = await waitUntil { recorded.count == 1 }; XCTAssertTrue(arrived)
        client.disconnect()
        XCTAssertEqual(client.appOperation?.phase, .unconfirmed)
        XCTAssertNil(client.appRuntime)
        client.connect(to: host)
        let reconnected = await waitUntil { client.canManageApps }; XCTAssertTrue(reconnected)
        XCTAssertEqual(recorded.count, 1, "reconnect must query state, never replay close")
        XCTAssertEqual(client.appOperation?.phase, .unconfirmed)
        client.disconnect(); client.forget(host); await mac.stop()
    }

    func testRingClearRetiresOldSamplesWithoutLosingNewSamples() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        input.frameLength = 256
        input.floatChannelData![0].initialize(repeating: 1, count: 256)
        let ring = PCMRing(channels: 1, capacity: 1024)
        XCTAssertTrue(ring.write(input))
        ring.clear()
        input.floatChannelData![0].update(repeating: 2, count: 256)
        XCTAssertTrue(ring.write(input))
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        output.frameLength = 512
        let taken = ring.read(into: UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList), frames: 512)
        XCTAssertEqual(taken, 256)
        XCTAssertTrue((0..<taken).allSatisfy { output.floatChannelData![0][$0] == 2 })
        XCTAssertEqual(ring.available, 0)
    }


    func testFreeLocalConnectionSendsPointerButNeverText() async throws {
        let mac = try TestMac()
        try await mac.start()
        defer { Task { await mac.stop() } }
        let host = pairedHost(mac)
        let client = NimletClient(proAccess: { false })
        client.disconnect()
        defer { client.forget(host) }
        client.connect(to: host)
        let connected = await waitUntil { client.state.isConnected && client.status?.deviceApproved == true }
        XCTAssertTrue(connected)
        let pointer = expectation(description: "Free LAN pointer reaches Mac")
        let text = expectation(description: "No text without Pro")
        text.isInverted = true
        mac.onMessage = { _, message in
            if case .move = message { pointer.fulfill() }
            if case .text = message { text.fulfill() }
        }
        client.sendMove(dx: 5, dy: 2)
        client.send(.text(TextPayload(text: "paste bypass", targetID: "app")))
        client.sendText("single target bypass", to: ["app"])
        XCTAssertTrue(client.showingPro)
        await fulfillment(of: [pointer, text], timeout: 1)
    }

    func testExpiryStopsStreamsAndKeepsFreeLANConnection() async throws {
        let storeSession = try SKTestSession(configurationFileNamed: "Nimlet")
        storeSession.resetToDefaultState()
        storeSession.disableDialogs = true
        storeSession.clearTransactions()
        defer { storeSession.clearTransactions() }
        let store = ProStore.shared
        let purchase = try await storeSession.buyProduct(identifier: ProStore.subscriptionIDs[0])
        await store.complete(.success(.success(.verified(purchase))))
        XCTAssertTrue(store.hasPro)
        let mac = try TestMac()
        try await mac.start()
        defer { Task { await mac.stop() } }
        let host = pairedHost(mac)
        let client = NimletClient()
        client.disconnect()
        defer { client.forget(host) }
        client.connect(to: host)
        let connected = await waitUntil { client.state.isConnected && client.status?.deviceApproved == true }
        XCTAssertTrue(connected)
        let panel = PanelClient()
        let audio = ListenClient()
        panel.start(control: client)
        audio.turnOn(control: client)
        defer { panel.stop(); audio.turnOff() }
        let streamsStarted = await waitUntil { panel.isConnected && audio.isOn }
        XCTAssertTrue(streamsStarted)
        try storeSession.expireSubscription(productIdentifier: ProStore.subscriptionIDs[0])
        let expired = await waitUntil(timeout: 60) { !store.hasPro && !panel.isConnected && !audio.isOn }
        XCTAssertTrue(expired)
        XCTAssertTrue(client.state.isConnected, "Expiry must keep free LAN controls usable")
        XCTAssertFalse(client.requirePro())
        XCTAssertTrue(client.showingPro)
    }

    // MARK: - Questions and approvals

    /// The whole phone half of "an agent needs you": a question with its
    /// choices arrives from the Mac, is drawn as a card, and the answer goes
    /// back to the Mac carrying the choices, so the hook that asked can hand
    /// them to its session.
    func testAQuestionReachesThePhoneAndItsAnswerGoesBack() async throws {
        let mac = try TestMac()
        let lock = NSLock()
        var decisions: [ClientMessage] = []
        let question = ApprovalRequest(
            id: "q-1", targetName: "Claude Code", title: "Has a question",
            detail: "Which database?\nWhich checks?", timeout: 3600,
            questions: [
                ApprovalQuestion(question: "Which database?", header: "Database",
                                 options: [ApprovalOption(label: "Postgres", detail: "The one in production"),
                                           ApprovalOption(label: "SQLite", detail: "Local only")]),
                ApprovalQuestion(question: "Which checks?", header: "Checks",
                                 options: [ApprovalOption(label: "Lint"), ApprovalOption(label: "Tests")],
                                 allowsMultiple: true),
            ],
            returnsToMac: true)
        let permission = ApprovalRequest(id: "p-1", targetName: "Claude Code", title: "Run a command",
                                         detail: "mkdir -p build-out && touch build-out/x.txt", kind: .command,
                                         timeout: 600, alwaysAllowRule: "mkdir -p build-out, touch build-out/x.txt",
                                         returnsToMac: true)
        mac.onMessage = { connection, message in
            switch message {
            case .requestPendingApprovals:
                mac.send(.pendingApprovals([question, permission]), on: connection)
            case .approvalDecision:
                lock.withLock { decisions.append(message) }
            default:
                break
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        defer { client.disconnect(); client.forget(host) }

        let arrived = await waitUntil { client.approvals.count == 2 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(client.approvals.first { $0.id == "q-1" }?.questions.count, 2,
                       "the choices survive the trip")

        // Drawn as the person sees it, for a look rather than an assertion.
        for (id, name) in [("q-1", "approval-question"), ("p-1", "approval-permission")] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            // A small phone's sheet, rather than whatever the test host is.
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 620)
            window.rootViewController = UIHostingController(rootView:
                ApprovalSheet(requests: client.approvals, focusID: id) { _, _ in }.preferredColorScheme(.dark))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            writeSnapshot(of: window, named: name)
            window.isHidden = true
            window.rootViewController = nil
        }

        client.decide("q-1", ApprovalAnswer(decision: .approve, answers: ["SQLite", "Lint, Tests"]))
        client.decide("p-1", ApprovalAnswer(decision: .approve, alwaysAllow: true))
        let answered = await waitUntil { lock.withLock { decisions.count } == 2 }
        XCTAssertTrue(answered)
        let sent = lock.withLock { decisions }
        guard case .approvalDecision(let id, let decision, _, let answers, _, let handBack) = sent[0] else {
            return XCTFail("the Mac heard something else")
        }
        XCTAssertEqual(id, "q-1")
        XCTAssertEqual(decision, .approve)
        XCTAssertEqual(answers, ["SQLite", "Lint, Tests"])
        XCTAssertNil(handBack)
        guard case .approvalDecision(let second, _, _, _, let always, _) = sent[1] else {
            return XCTFail("the Mac heard something else")
        }
        XCTAssertEqual(second, "p-1")
        XCTAssertEqual(always, true)
        XCTAssertTrue(client.approvals.isEmpty, "answered cards come down without waiting for the Mac")
    }

    /// Writes a PNG when `TEST_RUNNER_MICE_SNAPSHOT_DIR` is set; otherwise does
    /// nothing, so the suite never depends on a writable directory.
    private func writeSnapshot(of window: UIWindow, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MICE_SNAPSHOT_DIR"] else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 15, _ predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return predicate()
    }

    private func makeClient() -> NimletClient {
        let client = NimletClient(proAccess: { true })
        client.disconnect()
        return client
    }

    /// A Mac this phone has already paired with: its key pinned, and the given
    /// addresses remembered. Its Bonjour name is unique, so that route never
    /// answers and the race is always won by an address.
    private func pairedHost(_ mac: TestMac, at candidates: [NimletCandidate]? = nil) -> NimletClient.RememberedHost {
        let name = "Key Test \(UUID().uuidString.prefix(6))"
        let host = NimletClient.RememberedHost(name: name, locator: .bonjour(service: name, domain: "local."))
        PhoneTrust.remember(pin: mac.trust.identity.fingerprint, forHost: host.id)
        PhoneTrust.remember(candidates ?? [NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test")],
                            forHost: host.id)
        return host
    }

    /// A phone connected by key to `mac`.
    private func connectedClient(to mac: TestMac) async -> (NimletClient, NimletClient.RememberedHost) {
        let host = pairedHost(mac)
        let client = makeClient()
        client.connect(to: host)
        let connected = await waitUntil { client.state.isConnected }
        XCTAssertTrue(connected)
        return (client, host)
    }

    func testReconnectDoesNotWaitBehindPreviouslyUnusedAddresses() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let good = NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test")
        let silent = (1...5).map {
            NimletCandidate(host: "127.0.0.1", port: UInt16(10 + $0), reach: .local, via: "unused address")
        }
        PhoneTrust.remember(silent + [good], forHost: host.id)
        let started = Date()
        await withCheckedContinuation { continuation in
            mac.queue.async {
                mac.connections.forEach { $0.cancel() }
                mac.connections.removeAll()
                continuation.resume()
            }
        }
        let back = await waitUntil(timeout: 1.3) { mac.hellos >= 2 && client.state.isConnected }
        XCTAssertTrue(back, "Reconnect must reuse the proven address, not wait behind five silent ones")
        print("known-route reconnect: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testForegroundChecksASilentHeldSocketWithoutWaitingForIdleTimeout() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        await withCheckedContinuation { continuation in
            mac.queue.async {
                let stale = mac.connections.first
                mac.respondsToPing = { $0 !== stale }
                continuation.resume()
            }
        }
        client.enterBackground()
        let started = Date()
        client.enterForeground()
        let back = await waitUntil(timeout: 3.5) { mac.hellos >= 2 && client.state.isConnected }
        XCTAssertTrue(back, "A silent socket on resume must not cost the normal 12-second idle timeout")
        print("silent foreground reconnect: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testForegroundKeepsAResponsiveHeldSocket() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        client.enterBackground()
        client.enterForeground()
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertTrue(client.state.isConnected)
        XCTAssertEqual(mac.hellos, 1, "A healthy foreground resume must not rebuild the session")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testAnActiveSilentConnectionRecoversWithoutWaitingTwelveSeconds() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        await withCheckedContinuation { continuation in
            mac.queue.async {
                let stale = mac.connections.first
                mac.respondsToPing = { $0 !== stale }
                continuation.resume()
            }
        }
        let started = Date()
        let back = await waitUntil(timeout: 4.8) { mac.hellos >= 2 && client.state.isConnected }
        XCTAssertTrue(back, "Active input must recover after three missed pings, not the idle timeout")
        print("active silent reconnect: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testAnIdleConnectionKeepsItsLowFrequencyHeartbeatAndWakesWithoutRedial() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let idle = await waitUntil(timeout: 23) { client.isIdle }
        XCTAssertTrue(idle)
        // Take input just before the next idle ping: its previous pong is
        // older than the active timeout, but the connection is still healthy.
        try await Task.sleep(for: .seconds(4))
        client.send(.requestAppState)
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertTrue(client.state.isConnected)
        XCTAssertEqual(mac.hellos, 1, "Waking an idle connection must probe it, not falsely redial")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testAChangedNetworkRestartsAPendingHandshakeImmediately() async throws {
        let mac = try TestMac()
        mac.onHello = { connection in
            if mac.hellos > 1 { mac.welcome(connection) }
        }
        try await mac.start()
        let host = pairedHost(mac)
        let client = makeClient()
        client.connect(to: host)
        let pending = await waitUntil { mac.hellos == 1 }
        XCTAssertTrue(pending)
        XCTAssertFalse(client.state.isConnected)
        client.networkPathChanged(satisfied: true, signature: "old-network")
        let started = Date()
        client.networkPathChanged(satisfied: true, signature: "new-network")
        let back = await waitUntil(timeout: 1.3) { client.state.isConnected }
        XCTAssertTrue(back, "A usable replacement network must not wait for the stale handshake deadline")
        print("changed-path reconnect: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testForegroundRebuildsRacingAddressesRatherThanWaitingForTheOldDeadline() async throws {
        let mac = try TestMac()
        try await mac.start()
        let host = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: 11,
                                                     reach: .local, via: "old address")])
        let client = makeClient()
        client.connect(to: host)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(mac.hellos, 0)
        client.enterBackground()
        PhoneTrust.remember([NimletCandidate(host: "127.0.0.1", port: mac.port,
                                          reach: .local, via: "new address")], forHost: host.id)
        let started = Date()
        client.enterForeground()
        let back = await waitUntil(timeout: 1.3) { client.state.isConnected }
        XCTAssertTrue(back, "Resume must refresh a still-racing attempt, not retain its old addresses")
        print("racing foreground reconnect: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    private func invitation(for mac: TestMac, secret: Data? = nil) -> PairingInvitation {
        PairingInvitation(host: mac.trust.identity.fingerprint, secret: secret ?? mac.trust.secret,
                          name: "Key Test \(UUID().uuidString.prefix(6))",
                          addresses: ["127.0.0.1:\(mac.port)"])
    }

    private func remembered(_ invitation: PairingInvitation) -> NimletClient.RememberedHost {
        NimletClient.RememberedHost(name: invitation.name, locator: .bonjour(service: invitation.name, domain: "local."))
    }

    /// Scans a QR code and waits for the session that follows.
    private func pairedClient(_ invite: PairingInvitation) async -> NimletClient {
        let client = makeClient()
        XCTAssertTrue(client.acceptInvitation(invite.url))
        client.confirmPairing()
        let connected = await waitUntil { client.state.isConnected }
        XCTAssertTrue(connected)
        return client
    }

    // MARK: - Listening

    func testListeningReconnectsIfControlDropsAsPhoneEntersBackground() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.turnOn(control: client)
        let listening = await waitUntil { listen.isConnected }
        XCTAssertTrue(listening)
        mac.queue.async { mac.connections[0].cancel() }
        let dropped = await waitUntil { !client.state.isConnected }
        XCTAssertTrue(dropped)
        client.enterBackground()
        let recovered = await waitUntil { client.state.isConnected && listen.isConnected }
        XCTAssertTrue(recovered, "Listening must preserve a pending reconnect when locking during a network handoff")
        XCTAssertTrue(listen.isOn)
        client.enterForeground()
        listen.turnOff(); client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testListeningEpochRetiresCallbacksAcrossMuteResumeAndClose() {
        let stream = ListeningStream(held: false)
        let beforeHold = stream.epoch
        XCTAssertTrue(stream.accepts(beforeHold))
        stream.hold(true)
        XCTAssertFalse(stream.accepts(stream.epoch))
        stream.hold(false)
        XCTAssertFalse(stream.accepts(beforeHold), "A queued start before dictation must stay cancelled")
        XCTAssertTrue(stream.accepts(stream.epoch))
        stream.invalidate()
        XCTAssertFalse(stream.accepts(stream.epoch))
    }

    func testAudioDecoderRejectsInvalidWireFormatsAndPacketOverflow() {
        let decoder = AudioDecoder()
        for (rate, channels, blocks) in [(-1, 2, 1024), (48000, -1, 1024), (Int.max, 2, 1024),
                                        (48000, 2, Int.max), (48000, 99, 1024)] {
            var frame = AudioFrame(kind: .audio, captureTime: 0)
            frame.sampleRate = rate; frame.channels = channels; frame.framesPerPacket = blocks
            XCTAssertFalse(decoder.adopt(frame))
        }
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [1, Int.max]
        XCTAssertNil(frame.packetRanges(in: Data([0, 1])))
    }

    func testListeningReconnectUsesFreshFramerAndStopsOnControlDisconnect() async throws {
        let mac = try TestMac()
        var attempt = 0
        mac.onListenHello = { connection, _ in
            attempt += 1
            let data = try! AudioFrameWriter.encode(.state(attempt == 1 ? "old" : "fresh stream"), payload: Data())
            connection.send(content: attempt == 1 ? Data(data.prefix(7)) : data,
                            completion: .contentProcessed { _ in if attempt == 1 { connection.cancel() } })
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.turnOn(control: client)
        let recovered = await waitUntil { listen.message == "fresh stream" }
        XCTAssertTrue(recovered, "The old partial frame must not corrupt the next socket")
        client.disconnect()
        let stopped = await waitUntil { !listen.isOn }
        XCTAssertTrue(stopped)
        XCTAssertFalse(listen.isConnected)
        listen.turnOff(); client.forget(host)
        await mac.stop()
    }

    func testListenHoldBeforeEnableIsSentAndHostSwitchStopsListening() async throws {
        let mac = try TestMac()
        let held = expectation(description: "held hello")
        let resumed = expectation(description: "resumed hello")
        mac.onListenHello = { _, hello in
            if hello.isPaused { held.fulfill() } else { resumed.fulfill() }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.hold(true)
        listen.turnOn(control: client)
        await fulfillment(of: [held], timeout: 5)
        listen.hold(false)
        await fulfillment(of: [resumed], timeout: 5)
        let other = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: 9, reach: .local, via: "test")])
        client.connect(to: other)
        let stopped = await waitUntil { !listen.isOn }
        XCTAssertTrue(stopped, "Changing Macs must not leave the previous Mac playing")
        listen.turnOff(); client.disconnect(); client.forget(host); client.forget(other)
        await mac.stop()
    }

    func testListeningStopsWhenControlApprovalIsRevoked() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.turnOn(control: client)
        let listening = await waitUntil { listen.isConnected }
        XCTAssertTrue(listening)
        mac.queue.async {
            mac.send(.error(ConnectionRejection.revokedMessage), on: mac.connections[0])
        }
        let stopped = await waitUntil { !listen.isOn }
        XCTAssertTrue(stopped)
        XCTAssertEqual(client.failure?.kind, .revoked)
        listen.turnOff(); client.disconnect(); client.forget(host)
        await mac.stop()
    }

    /// Real AAC encoder/decoder and AVAudioEngine on iOS. Only synthetic silence
    /// crosses these TLS sockets; no microphone or system capture is involved.
    func testAudioPlaybackLocallyMutesInflightFramesAndCannotRestartAfterOff() async throws {
        let mac = try TestMac()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        pcm.frameLength = 4096
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0, count: 4096) }
        let encoder = AudioEncoder()
        var wire = Data()
        for _ in 0..<10 {
            guard let out = encoder.encode(pcm) else { continue }
            var frame = AudioFrame(kind: .audio, captureTime: Instrumentation.now())
            frame.codec = .aac; frame.sampleRate = 48000; frame.channels = 2
            frame.framesPerPacket = 1024; frame.packets = out.packets
            wire.append(try AudioFrameWriter.encode(frame, payload: out.data))
        }
        XCTAssertFalse(wire.isEmpty)
        let audio = wire
        let timer = DispatchSource.makeTimerSource(queue: mac.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(150))
        var listenSocket: NWConnection?
        // Intentionally keep sending after a pause to exercise the local gate.
        mac.onListenHello = { connection, _ in listenSocket = connection }
        timer.setEventHandler { listenSocket?.send(content: audio, completion: .contentProcessed { _ in }) }
        timer.resume()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.turnOn(control: client)
        let played = await waitUntil { listen.isPlaying }
        XCTAssertTrue(played, "AAC frames must reach the actual iOS playback engine")
        listen.hold(true)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(listen.isPlaying, "Even a host that keeps sending must stay muted during dictation")
        listen.hold(false)
        let resumed = await waitUntil { listen.isPlaying }
        XCTAssertTrue(resumed)
        listen.turnOff()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(listen.isOn)
        XCTAssertFalse(listen.isPlaying, "In-flight frames must not resurrect playback")
        timer.cancel()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    /// The second sockets present the same key: a trust listener has nothing
    /// else to let them in by.
    func testTheListenSocketConnectsByKeyToo() async throws {
        let mac = try TestMac()
        mac.onListenHello = { connection, _ in
            let byKey = TrustTransport.peerFingerprint(of: connection) == PhoneTrust.identity?.fingerprint
            connection.send(content: try! AudioFrameWriter.encode(.state(byKey ? "authenticated by key" : "wrong key"),
                                                                 payload: Data()),
                            completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let listen = ListenClient()
        listen.turnOn(control: client)
        let authenticated = await waitUntil { listen.message == "authenticated by key" }
        XCTAssertTrue(authenticated, "the listen socket must pin the Mac and present this phone's key")
        listen.turnOff(); client.disconnect(); client.forget(host)
        await mac.stop()
    }

    // MARK: - Pairing by key

    /// The whole of it: scan, prove, be let in, and come back later by key.
    func testScanningTheMacsCodePairsByKeyAndReconnectsByKey() async throws {
        let mac = try TestMac(paired: false)
        try await mac.start()
        let invite = invitation(for: mac)
        let client = await pairedClient(invite)
        XCTAssertEqual(client.session?.pin, mac.trust.identity.fingerprint)
        XCTAssertEqual(mac.trust.approvedKeys, [PhoneTrust.identity!.fingerprint],
                       "the Mac must have approved the key the phone proved, not anything it said")
        let host = remembered(invite)
        XCTAssertEqual(PhoneTrust.pin(forHost: host.id), mac.trust.identity.fingerprint)

        client.disconnect()
        client.connect(to: host)
        let back = await waitUntil { client.state.isConnected }
        XCTAssertTrue(back)
        XCTAssertEqual(mac.pairs, 1, "a reconnect is by key; it never pairs again")
        XCTAssertEqual(mac.hellos, 2)

        client.disconnect(); client.forget(host)
        XCTAssertNil(PhoneTrust.pin(forHost: host.id))
        await mac.stop()
    }

    /// A link can come from anywhere. Until the person says yes, nothing is
    /// dialled and nothing is remembered.
    func testAPairingLinkDoesNothingUntilConfirmed() async throws {
        let mac = try TestMac(paired: false)
        try await mac.start()
        let invite = invitation(for: mac)
        let client = makeClient()
        XCTAssertTrue(client.acceptInvitation(invite.url))
        XCTAssertEqual(client.pendingPairing?.invitation, invite)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(mac.pairs, 0)
        XCTAssertTrue(PhoneTrust.candidates(forHost: remembered(invite).id).isEmpty,
                      "a link's addresses are not kept before its Mac has proved its key")
        client.cancelPairing()
        XCTAssertNil(client.pendingPairing)
        client.disconnect(); client.forget(remembered(invite))
        await mac.stop()
    }

    func testACodeThatIsNotTheMacsIsRefusedWithoutConnecting() async throws {
        let mac = try TestMac(paired: false)
        try await mac.start()
        let invite = invitation(for: mac, secret: PairingProof.newSecret())
        let client = makeClient()
        client.acceptInvitation(invite.url)
        client.confirmPairing()
        let refused = await waitUntil { client.failure?.kind == .notPaired }
        XCTAssertTrue(refused)
        XCTAssertFalse(client.state.isConnected)
        XCTAssertEqual(mac.hellos, 0, "nothing but pair is said before the Mac has said yes")
        XCTAssertTrue(mac.trust.approvedKeys.isEmpty)
        XCTAssertNil(PhoneTrust.pin(forHost: remembered(invite).id))
        client.disconnect(); client.forget(remembered(invite))
        await mac.stop()
    }

    /// The phone pins the key from the QR code. A listener with any other key
    /// — another Mac, or something in the middle — is refused by the phone.
    func testThePhoneRefusesAListenerWithADifferentKey() async throws {
        let mac = try TestMac(paired: false)
        try await mac.start()
        let impostor = try TrustIdentity(privateKey: P256.Signing.PrivateKey())
        let invite = PairingInvitation(host: impostor.fingerprint, secret: mac.trust.secret,
                                       name: "Key Test \(UUID().uuidString.prefix(6))",
                                       addresses: ["127.0.0.1:\(mac.port)"])
        let client = makeClient()
        client.acceptInvitation(invite.url)
        client.confirmPairing()
        let refused = await waitUntil { client.failure?.kind == .notPaired }
        XCTAssertTrue(refused)
        XCTAssertEqual(mac.pairs, 0, "no proof may be sent to a Mac whose key is not the pinned one")
        client.disconnect(); client.forget(remembered(invite))
        await mac.stop()
    }

    /// TLS 1.3 lets the phone finish before the Mac has judged its key, so a
    /// revoked phone sees the link come up and then close. That has to end in
    /// "pair again", not in a reconnect loop.
    func testARevokedKeyEndsInPairAgainRatherThanARedialLoop() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        mac.trust.revokeAll()
        client.disconnect()
        client.connect(to: host)
        let refused = await waitUntil { client.failure?.kind == .notPaired }
        XCTAssertTrue(refused)
        XCTAssertFalse(client.state.isConnected)
        let hellos = mac.hellos
        try? await Task.sleep(for: .seconds(3))
        XCTAssertEqual(mac.hellos, hellos, "a refused key must not be redialled")
        XCTAssertNil(client.retryingSince)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    // MARK: - A new iPhone

    /// A new iPhone set up from the old one's backup brings the old phone's
    /// pins and remembered Macs, and not its key — that is `ThisDeviceOnly`.
    /// The pins go before anything dials, the Mac stays listed to pair with
    /// again, and its code gets this phone back in.
    func testARestoredPhoneDropsTheOldPhonesPinsAndPairsAgain() async throws {
        let mac = try TestMac(paired: false)
        try await mac.start()
        let invite = invitation(for: mac)
        let host = remembered(invite)
        let old = await pairedClient(invite)
        old.disconnect()
        XCTAssertNotNil(PhoneTrust.pin(forHost: host.id))

        // What a restore leaves behind: the same preferences, made under
        // another phone's key.
        let oldPhone = try TrustIdentity(privateKey: P256.Signing.PrivateKey())
        UserDefaults.standard.set(oldPhone.fingerprint.description, forKey: "mice.trust.owner.v1")

        let restored = makeClient()
        XCTAssertNil(PhoneTrust.pin(forHost: host.id), "a pin this key never earned is not dialled")
        XCTAssertTrue(restored.rememberedHosts.contains { $0.id == host.id }, "the Mac stays listed, to pair again")
        XCTAssertFalse(restored.hasCredential(for: host))
        XCTAssertNotEqual(restored.deviceID, old.deviceID,
                          "the Mac must not list the new phone under the old one's name")
        let hellos = mac.hellos
        restored.retry()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(mac.hellos, hellos, "nothing dials a Mac this phone holds no pin for")

        restored.pair(with: invite)
        let back = await waitUntil { restored.state.isConnected }
        XCTAssertTrue(back)
        XCTAssertEqual(PhoneTrust.pin(forHost: host.id), mac.trust.identity.fingerprint)

        // And the next launch keeps them: they are this key's pins now.
        let relaunched = makeClient()
        XCTAssertTrue(relaunched.hasCredential(for: host))
        restored.disconnect(); relaunched.disconnect(); restored.forget(host)
        await mac.stop()
    }

    /// Before the owner was recorded, a key made by this launch beside pins
    /// that were not is the one sign of a restore. An update brings back both
    /// the key and the pins; a reinstall brings back the key and no pins.
    func testPinsWithNoRecordedOwnerAreKeptUnlessTheKeyIsNew() throws {
        let ownerKey = "mice.trust.owner.v1"
        let hostID = "bonjour:Owner Test \(UUID().uuidString.prefix(6)).local."
        let pin = try TrustIdentity(privateKey: P256.Signing.PrivateKey()).fingerprint
        defer {
            PhoneTrust.forget(hostID: hostID)
            _ = PhoneTrust.dropPinsMadeByAnotherKey(keyIsNew: false)
        }

        PhoneTrust.remember(pin: pin, forHost: hostID)
        UserDefaults.standard.removeObject(forKey: ownerKey)
        XCTAssertFalse(PhoneTrust.dropPinsMadeByAnotherKey(keyIsNew: false), "an update keeps its pins")
        XCTAssertEqual(PhoneTrust.pin(forHost: hostID), pin)
        XCTAssertFalse(PhoneTrust.dropPinsMadeByAnotherKey(keyIsNew: true),
                       "once the owner is recorded, it decides")
        XCTAssertEqual(PhoneTrust.pin(forHost: hostID), pin)

        UserDefaults.standard.removeObject(forKey: ownerKey)
        XCTAssertTrue(PhoneTrust.dropPinsMadeByAnotherKey(keyIsNew: true), "a new key beside old pins is a restore")
        XCTAssertNil(PhoneTrust.pin(forHost: hostID))
    }

    // MARK: - Reaching the Mac

    /// Through the relay: the phone dials the relay's address, names the Mac's
    /// route in its ClientHello, and is still pinned end to end. A forwarder
    /// stands in for the relay here — it records what the phone asked for and
    /// passes the bytes on unread, which is all the real one does with them.
    func testAPhonePairedByKeyReachesTheMacThroughARelay() async throws {
        let mac = try TestMac()
        mac.onListenHello = { connection, _ in
            connection.send(content: try! AudioFrameWriter.encode(.state("heard through the relay"), payload: Data()),
                            completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!)
        try await relay.start()
        let host = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay")])
        let client = makeClient()
        client.connect(to: host)
        let connected = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(client.session?.reach, .relay)
        XCTAssertEqual(client.connectionRouteDescription.hasPrefix("Relay"), true)
        XCTAssertTrue(relay.routeProtocols.contains(RelayRoute.applicationProtocol(for: mac.trust.identity.fingerprint)),
                      "the phone must route through ALPN: \(relay.routeProtocols)")
        XCTAssertTrue(relay.serverNames.isEmpty, "A synthetic DNS name must not reach the VPN proxy")

        let listen = ListenClient()
        listen.turnOn(control: client)
        let heard = await waitUntil { listen.message == "heard through the relay" }
        XCTAssertTrue(heard, "second sockets must go through the relay with the same route and key")
        listen.turnOff(); client.disconnect(); client.forget(host)
        relay.stop()
        await mac.stop()
    }

    /// Addresses are raced, not tried in turn: one that swallows the SYN does
    /// not hold up the one behind it.
    func testAnAddressThatNeverAnswersDoesNotHoldUpTheOneThatDoes() async throws {
        let mac = try TestMac()
        try await mac.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "192.0.2.1", port: 61433, reach: .local, via: "nowhere"),
            NimletCandidate(host: "::1", port: mac.port, reach: .internet6, via: "test"),
        ])
        let client = makeClient()
        client.connect(to: host)
        let connected = await waitUntil(timeout: 4) { client.state.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(client.session?.reach, .internet6)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    /// A session by key that drops comes back by itself rather than asking to
    /// pair again. On loopback the drop arrives as end-of-stream on a read;
    /// the other way it can arrive — the connection's own `.failed`, which is
    /// what an interface change produces — cannot be forced here, and is
    /// covered by `connectionFailed` sending a connected session to
    /// `dropAndReconnect`.
    func testADroppedSessionByKeyReconnectsRatherThanAskingToPairAgain() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let hellos = mac.hellos
        mac.queue.sync { mac.connections.forEach { $0.cancel() } }
        let back = await waitUntil(timeout: 20) { client.state.isConnected && mac.hellos > hellos }
        XCTAssertTrue(back)
        XCTAssertNil(client.failure)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    /// A relay that hangs up mid-handshake — its Mac asleep, say — is a link
    /// problem, not a verdict on the key.
    func testARelayHangingUpMidHandshakeIsNotReadAsUnpaired() async throws {
        let mac = try TestMac()
        try await mac.start()
        let hangup = try NWListener(using: .tcp, on: .any)
        hangup.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in connection.cancel() }
        }
        hangup.start(queue: .global())
        let up = await waitUntil { hangup.port != nil }
        XCTAssertTrue(up)
        let host = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: hangup.port!.rawValue, reach: .relay, via: "relay")])
        let client = makeClient()
        client.connect(to: host)
        try? await Task.sleep(for: .seconds(8))
        XCTAssertNotEqual(client.failure?.kind, .notPaired, "\(String(describing: client.failure))")
        XCTAssertFalse(client.state.isConnected)
        client.disconnect(); client.forget(host)
        hangup.cancel()
        await mac.stop()
    }

    func testClosedTLSRoutesRetryWithoutWaitingForTheTenSecondDeadline() async throws {
        let mac = try TestMac()
        let name = "Closed TLS \(UUID().uuidString.prefix(6))"
        let hangup = try NWListener(using: .tcp, on: .any)
        hangup.service = NWListener.Service(name: name, type: NimletProtocol.trustBonjourType)
        hangup.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in connection.cancel() }
        }
        hangup.start(queue: .global())
        let up = await waitUntil { hangup.port != nil }
        XCTAssertTrue(up)
        let host = NimletClient.RememberedHost(name: name, locator: .bonjour(service: name, domain: "local."))
        PhoneTrust.remember(pin: mac.trust.identity.fingerprint, forHost: host.id)
        PhoneTrust.remember([NimletCandidate(host: "127.0.0.1", port: hangup.port!.rawValue, reach: .relay, via: "test")],
                            forHost: host.id)
        let client = makeClient()
        defer { client.disconnect(); client.forget(host); hangup.cancel() }
        // Drive the production path callback: cellular has no Bonjour route.
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        let start = Date()
        client.connect(to: host)
        let failed = await waitUntil(timeout: 2) { client.failure != nil }
        XCTAssertTrue(failed, "A closed TLS socket must leave the race immediately")
        XCTAssertEqual(client.failure?.kind, .unreachable, "A transport close does not revoke the pinned key")
        print("closed TLS routes retired: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    func testAutomaticReconnectAndForegroundResumeKeepTheRemoteRoute() async throws {
        let mac = try TestMac()
        try await mac.start()
        let host = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .forwarded4, via: "test")])
        let client = makeClient()
        client.connect(to: host)
        let connected = await waitUntil { client.state.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(client.session?.reach, .forwarded4)
        let firstConnection = client.lastConnectedAt
        mac.queue.async { mac.connections.forEach { $0.cancel() } }
        let reconnected = await waitUntil { client.state.isConnected && client.lastConnectedAt != firstConnection }
        XCTAssertTrue(reconnected, "A dropped session must race the remembered addresses again")
        client.disconnect()
        client.retry()
        let retried = await waitUntil { client.state.isConnected }
        XCTAssertTrue(retried, "Try again must rebuild the whole race")
        client.enterBackground()
        // Let the production foreground path redial after a remote close.
        mac.queue.async { mac.connections.forEach { $0.cancel() } }
        try? await Task.sleep(for: .milliseconds(100))
        client.enterForeground()
        let resumed = await waitUntil { client.state.isConnected }
        XCTAssertTrue(resumed)
        client.enterBackground()
        try? await Task.sleep(for: .seconds(26))
        XCTAssertFalse(client.state.isConnected)
        client.enterForeground()
        let foreground = await waitUntil { client.state.isConnected }
        XCTAssertTrue(foreground, "Suspension must not discard the remembered Mac")
        XCTAssertEqual(client.session?.reach, .forwarded4)
        client.disconnect()
        let relaunched = NimletClient(proAccess: { true })
        relaunched.enterForeground()
        let coldLaunch = await waitUntil { relaunched.state.isConnected }
        XCTAssertTrue(coldLaunch, "Cold launch must dial the stored addresses")
        relaunched.disconnect()
        relaunched.forget(host)
        await mac.stop()
    }

    func testRemoteSetupPersistsVPNAndOffReasonWithoutAPushKey() async throws {
        let mac = try TestMac()
        let vpn = NimletCandidate(host: "100.101.102.103", port: 61433, reach: .local, via: "VPN")
        let reason = "Direct internet access is off. Connect Tailscale on both devices."
        mac.onHello = { connection in
            mac.welcome(connection)
            mac.send(.remoteAccess(RemoteAccessPayload(isEnabled: false, candidates: [vpn], unavailable: reason)),
                     on: connection)
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let received = await waitUntil { PhoneTrust.candidates(forHost: host.id) == [vpn] }
        XCTAssertTrue(received)
        XCTAssertEqual(PhoneTrust.awayEnabled(forHost: host.id), false)
        XCTAssertEqual(client.cellularReadiness, reason)
        XCTAssertEqual(PhoneTrust.unavailable(forHost: host.id), reason)
        XCTAssertNil(SecretStore.read(service: SecretStore.awayService, account: host.id))
        XCTAssertTrue(LaunchNetworkPolicy.allowsAwayAccess)
        XCTAssertFalse(client.session?.parameters?.prohibitedInterfaceTypes?.contains(.cellular) ?? false)
        client.disconnect(); client.forget(host)
        XCTAssertNil(PhoneTrust.unavailable(forHost: host.id))
        await mac.stop()
    }

    // MARK: - Refusals and deadlines

    func testRevokedReplyAndEOFStopReconnectAndNeverClaimConnected() async throws {
        let mac = try TestMac()
        mac.onHello = { mac.send(.error(ConnectionRejection.revokedMessage), on: $0, close: true) }
        try await mac.start()
        let host = pairedHost(mac)
        let client = makeClient()
        client.connect(to: host)
        let refused = await waitUntil { client.failure?.kind == .revoked }
        XCTAssertTrue(refused)
        XCTAssertFalse(client.state.isConnected)
        XCTAssertNil(client.lastConnectedAt)
        XCTAssertNil(client.retryingSince)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(client.failure?.kind, .revoked, "EOF must not overwrite the refusal")
        client.enterBackground()
        client.enterForeground()
        XCTAssertFalse(client.state.isConnected)
        XCTAssertEqual(client.failure?.kind, .revoked)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testVersionRefusalIsTerminalAndExplicitRetryCanRecover() async throws {
        let mac = try TestMac()
        mac.onHello = { mac.send(.error(NimletProtocol.versionRefusal(clientVersion: 99)), on: $0, close: true) }
        try await mac.start()
        let host = pairedHost(mac)
        let client = makeClient()
        client.connect(to: host)
        let refused = await waitUntil { client.failure?.kind == .versionMismatch }
        XCTAssertTrue(refused)
        XCTAssertNil(client.lastConnectedAt)
        mac.queue.async { mac.onHello = { mac.welcome($0) } }
        client.retry()
        let recovered = await waitUntil { client.state.isConnected }
        XCTAssertTrue(recovered)
        XCTAssertNil(client.failure)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testBonjourVersionMismatchStopsBeforeOpeningASocket() {
        let client = makeClient()
        let remembered = NimletClient.RememberedHost(name: "Newer Mac", locator: .bonjour(service: "newer", domain: "local."))
        let host = NimletClient.DiscoveredHost(id: remembered.id, name: remembered.name,
                                             remembered: remembered, version: NimletProtocol.version + 1)
        client.connect(to: host)
        XCTAssertEqual(client.failure?.kind, .versionMismatch)
        XCTAssertFalse(client.state.isConnected)
        XCTAssertNil(client.session)
        XCTAssertNil(client.retryingSince)
        client.enterForeground()
        XCTAssertEqual(client.failure?.kind, .versionMismatch)
        client.disconnect()
    }

    func testPanelRecoversFromSilentTLSHandshakeWithoutDroppingControl() async throws {
        let mac = try TestMac()
        var accepted = 0
        // Accept the control socket, then leave the first panel's TLS handshake
        // unanswered. The next panel socket can use the same pinned identity.
        mac.shouldStartConnection = { _ in
            accepted += 1
            return accepted != 2
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        panel.start(control: client)
        let recovered = await waitUntil(timeout: 12) { !mac.viewHellos.isEmpty }
        XCTAssertTrue(recovered, "A silent panel handshake must retry within a bounded time")
        XCTAssertTrue(panel.isConnected)
        XCTAssertTrue(client.state.isConnected)
        XCTAssertEqual(mac.hellos, 1, "Recover the panel without tearing down healthy control")
        panel.stop()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testWindowFitIsIndependentOfZoomCropAndReconnect() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        panel.setWindowFit(points: CGSize(width: 360, height: 260))
        panel.setViewport(points: CGSize(width: 360, height: 260))
        panel.start(control: client)
        let fitted = await waitUntil { mac.viewHellos.last?.fitAspect == 1.385 }
        XCTAssertTrue(fitted)
        let width = try XCTUnwrap(mac.viewHellos.last?.maxWidth)
        panel.setViewport(points: CGSize(width: 1080, height: 780))
        panel.setCrop(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4))
        let zoomed = await waitUntil { mac.viewHellos.last?.maxWidth != width && mac.viewHellos.last?.crop != nil }
        XCTAssertTrue(zoomed)
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, 1.385)
        panel.stop()
        panel.start(control: client)
        let count = mac.viewHellos.count
        let reconnected = await waitUntil { mac.viewHellos.count > count }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, 1.385)
        panel.setWindowFit(points: CGSize(width: 360, height: 640))
        let changedLayout = await waitUntil { mac.viewHellos.last?.fitAspect == 0.563 }
        XCTAssertTrue(changedLayout)
        panel.stop()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testDefaultStageRequestsWindowFitWithoutDragging() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            ContentView().environmentObject(client).environmentObject(panel)
                .environmentObject(VoiceCapture()).environmentObject(ListenClient())
                .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        let requested = await waitUntil { mac.viewHellos.last?.fitAspect != nil }
        XCTAssertTrue(requested, "The default stage must send its available area without a seam drag")
        let aspect = try XCTUnwrap(mac.viewHellos.last?.fitAspect)
        XCTAssertGreaterThan(aspect, 0.5)
        XCTAssertLessThan(aspect, 4)
        window.isHidden = true
        window.rootViewController = nil
        panel.stop()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testKeyboardAreaBoundsStageAndRestoresOriginalWindowFit() async throws {
        let mac = try TestMac()
        mac.onViewHello = { connection in
            // A tall, fixed-size Mac window reproduces the user's screenshot.
            // Metadata is sufficient; this test does not claim decoded video.
            var frame = ViewFrame(kind: .video, title: "Keyboard layout QA", captureTime: Instrumentation.now())
            frame.width = 700; frame.height = 1000
            connection.send(content: try! ViewFrameWriter.encode(frame, payload: Data()),
                            completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView:
            ContentView().environmentObject(client).environmentObject(panel)
                .environmentObject(VoiceCapture()).environmentObject(ListenClient())
                .environment(\.scenePhase, .active))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            window.isHidden = true; window.rootViewController = nil
            panel.stop(); client.disconnect(); client.forget(host)
        }
        let ready = await waitUntil { panel.isVideo && mac.viewHellos.last?.fitAspect != nil }
        XCTAssertTrue(ready)
        try await Task.sleep(for: .milliseconds(700))
        let original = try XCTUnwrap(mac.viewHellos.last)

        // The hosting controller's safe area models the keyboard's occupied
        // region. The notification suspends Mac resizing through the real view.
        let fullHeight = controller.view.safeAreaLayoutGuide.layoutFrame.height
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        controller.additionalSafeAreaInsets.bottom = max(fullHeight - 320, 0)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        let typing = try XCTUnwrap(mac.viewHellos.last)
        let available = controller.view.safeAreaLayoutGuide.layoutFrame.height
        XCTAssertGreaterThan(available, 200, "The fixture must leave a usable area above the keyboard")
        XCTAssertLessThanOrEqual(CGFloat(typing.maxHeight), available * window.screen.scale + 16,
                                 "The mirror must fit above the keyboard, leaving room for the composer and status")
        XCTAssertEqual(typing.fitAspect, original.fitAspect, "Typing must not reshape the Mac window")

        controller.additionalSafeAreaInsets.bottom = 0
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        controller.view.layoutIfNeeded()
        let restored = await waitUntil { mac.viewHellos.last?.maxHeight == original.maxHeight }
        XCTAssertTrue(restored, "Dismissing the keyboard must restore the previous mirror size")
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, original.fitAspect)
        await mac.stop()
    }

    func testTypingViewportCannotChangeWindowFitAndReconnectKeepsOriginalShape() async throws {
        let mac = try TestMac()
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        panel.setWindowFit(points: CGSize(width: 360, height: 600))
        panel.setViewport(points: CGSize(width: 360, height: 600))
        panel.start(control: client)
        let ready = await waitUntil { mac.viewHellos.last?.fitAspect == 0.6 }; XCTAssertTrue(ready)
        panel.setWindowFitSuspended(true)
        panel.setWindowFit(points: CGSize(width: 360, height: 180))
        panel.setViewport(points: CGSize(width: 360, height: 180))
        let typing = await waitUntil { mac.viewHellos.last?.maxHeight == 544 }; XCTAssertTrue(typing)
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, 0.6, "keyboard layout changes encoding size, never the Mac window")
        panel.stop(); panel.start(control: client)
        let count = mac.viewHellos.count
        let reconnected = await waitUntil { mac.viewHellos.count > count }; XCTAssertTrue(reconnected)
        panel.setWindowFit(points: CGSize(width: 360, height: 220))
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, 0.6, "typing remains suspended through a reconnect")
        panel.setWindowFitSuspended(false)
        panel.setWindowFit(points: CGSize(width: 360, height: 600))
        panel.setViewport(points: CGSize(width: 360, height: 600))
        let restored = await waitUntil { mac.viewHellos.last?.maxHeight == 1800 }; XCTAssertTrue(restored)
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, 0.6, "input completion restores the original shape")
        panel.stop(); client.disconnect(); client.forget(host); await mac.stop()
    }

    func testWindowPickerDoesNotPresentSheetOrResizeMirror() async throws {
        let mac = try TestMac()
        let target = NimletTarget(id: "picker-qa", name: "Picker QA", kind: .app, bundleID: "org.nimlet.QA", symbol: "app")
        mac.onHello = { connection in
            mac.send(.welcome(status: HostStatus(hostName: "Test Mac", accessibilityGranted: true,
                injectionPaused: false, activeTargetID: target.id, deviceApproved: true), targets: [target]), on: connection)
        }
        mac.onMessage = { connection, message in
            if case .requestWindows(let id) = message {
                mac.send(.windows(WindowListPayload(targetID: id, windows: [
                    MacWindow(id: 42, title: "QA window", appName: target.name, isFrontmost: true)
                ])), on: connection)
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView:
            ContentView().environmentObject(client).environmentObject(panel)
                .environmentObject(VoiceCapture()).environmentObject(ListenClient())
                .environment(\.scenePhase, .active))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let loaded = await waitUntil { mac.viewHellos.last?.fitAspect != nil && client.targets.contains { $0.id == target.id } }
        XCTAssertTrue(loaded, "the control surface must mount before opening its window picker")
        let originalFit = try XCTUnwrap(mac.viewHellos.last?.fitAspect)
        client.shelfRequestID = target.id
        let shown = await waitUntil { client.windowRoster(for: target.id)?.windows.count == 1 }
        XCTAssertTrue(shown, "opening the picker must request the app's actual windows")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(controller.presentedViewController, "the horizontal picker must stay on the control surface")
        XCTAssertEqual(mac.viewHellos.last?.fitAspect, originalFit,
                       "opening the picker must not resize the Mac window")
        window.isHidden = true; window.rootViewController = nil
        panel.stop(); client.disconnect(); client.forget(host); await mac.stop()
    }

    func testDetailMirrorRequestsANewFitWhenItsAvailableAreaChanges() async throws {
        let mac = try TestMac()
        var sentGeometry = false
        mac.onViewHello = { connection in
            guard !sentGeometry else { return }
            sentGeometry = true
            // Geometry metadata is enough for this layout test. No encoded
            // picture is claimed; subsequent keyframe requests are left idle.
            var frame = ViewFrame(kind: .video, title: "Wide window", captureTime: Instrumentation.now())
            frame.width = 1200; frame.height = 400
            let data = try! ViewFrameWriter.encode(frame, payload: Data())
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        panel.start(control: client)
        let receivedGeometry = await waitUntil { panel.isVideo }
        XCTAssertTrue(receivedGeometry)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView:
            PanelViewer(onClose: {}).frame(width: 360, height: 640)
                .environmentObject(client).environmentObject(panel))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let fitted = await waitUntil { mac.viewHellos.last?.fitAspect != nil }
        XCTAssertTrue(fitted)
        let portrait = try XCTUnwrap(mac.viewHellos.last?.fitAspect)
        XCTAssertLessThan(portrait, 1)
        controller.rootView = PanelViewer(onClose: {}).frame(width: 640, height: 360)
            .environmentObject(client).environmentObject(panel)
        let rotated = await waitUntil { (mac.viewHellos.last?.fitAspect ?? 0) > 1 }
        XCTAssertTrue(rotated)
        window.isHidden = true
        window.rootViewController = nil
        panel.stop()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testStageViewportDoesNotFollowIncomingFrameSize() async throws {
        try await checkViewportStability(detail: false)
    }

    func testDetailStartsFittedAndViewportDoesNotFollowIncomingFrameSize() async throws {
        try await checkViewportStability(detail: true)
    }

    private func checkViewportStability(detail: Bool) async throws {
        let previousShare = UserDefaults.standard.object(forKey: "mice.stage.share")
        UserDefaults.standard.set(0.8, forKey: "mice.stage.share")
        defer {
            if let previousShare { UserDefaults.standard.set(previousShare, forKey: "mice.stage.share") }
            else { UserDefaults.standard.removeObject(forKey: "mice.stage.share") }
        }
        let mac = try TestMac()
        var sentGeometry = false
        mac.onViewHello = { _ in
            guard !sentGeometry else { return }
            sentGeometry = true
            mac.sendViewGeometry(width: 1750, height: 2304)
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let view: AnyView
        if detail {
            view = AnyView(PanelViewer(onClose: {}).frame(width: 360, height: 640)
                .environmentObject(client).environmentObject(panel))
        } else {
            view = AnyView(ContentView().environmentObject(client).environmentObject(panel)
                .environmentObject(VoiceCapture()).environmentObject(ListenClient())
                .environment(\.scenePhase, .active))
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        if detail { panel.start(control: client) }
        defer {
            window.isHidden = true; window.rootViewController = nil
            panel.stop(); client.disconnect(); client.forget(host)
        }
        let ready = await waitUntil { mac.viewHellos.last?.fitAspect != nil && panel.isVideo }
        XCTAssertTrue(ready)
        try await Task.sleep(for: .milliseconds(700))
        let before = try XCTUnwrap(mac.viewHellos.last)
        if detail {
            let offeredWidth = Int((360 * UITraitCollection.current.displayScale / 8).rounded() * 8)
            XCTAssertEqual(before.maxWidth, offeredWidth, "Detail must open showing the whole window")
        }
        // Include the exact rounding pair observed on the physical phone,
        // plus a much wider frame. Neither changes the phone's available area.
        for size in [(1752, 2306), (1750, 2304), (1200, 400)] {
            mac.sendViewGeometry(width: size.0, height: size.1)
            try await Task.sleep(for: .milliseconds(180))
        }
        try await Task.sleep(for: .milliseconds(700))
        let after = try XCTUnwrap(mac.viewHellos.last)
        XCTAssertEqual(after.maxWidth, before.maxWidth)
        XCTAssertEqual(after.maxHeight, before.maxHeight)
        XCTAssertEqual(after.fitAspect, before.fitAspect)
        await mac.stop()
    }

    func testMirrorRecoversAfterPartialFrameAndConnectionReplacement() async throws {
        let mac = try TestMac()
        var attempts = 0
        mac.onViewHello = { connection in
            attempts += 1
            let bytes = try! ViewFrameWriter.encode(.state("Fresh frame", title: "Test window"), payload: Data())
            if attempts == 1 {
                connection.send(content: bytes.prefix(7), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                connection.send(content: bytes, completion: .contentProcessed { _ in })
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        panel.start(control: client)
        let recovered = await waitUntil { panel.message == "Fresh frame" }
        XCTAssertTrue(recovered)
        XCTAssertEqual(panel.title, "Test window")
        panel.stop()
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testVisibleMirrorStartsWhenControlConnectsAfterViewAppears() async throws {
        let mac = try TestMac()
        mac.onViewHello = { connection in
            let bytes = try! ViewFrameWriter.encode(.state("Lifecycle frame", title: "Test window"), payload: Data())
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let client = makeClient()
        let host = pairedHost(mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            Color.clear.modifier(PanelLifecycle(shown: true))
                .environmentObject(client).environmentObject(panel)
                .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(panel.isConnected)
        client.connect(to: host)
        let received = await waitUntil { panel.message == "Lifecycle frame" }
        XCTAssertTrue(received, "An already-visible mirror must start when control connects")
        XCTAssertTrue(panel.isConnected)
        client.disconnect()
        let stopped = await waitUntil { !panel.isConnected }
        XCTAssertTrue(stopped, "Disconnect must stop the picture socket")
        panel.stop()
        window.isHidden = true
        window.rootViewController = nil
        client.forget(host)
        await mac.stop()
    }

    func testTLSReadyWithoutWelcomeTimesOutInsteadOfShowingTrackpad() async throws {
        let mac = try TestMac()
        mac.onHello = { _ in }
        try await mac.start()
        let host = pairedHost(mac)
        let client = makeClient()
        client.connect(to: host)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(client.state.isConnected)
        let failed = await waitUntil(timeout: 13) { client.failure?.kind == .unreachable }
        XCTAssertTrue(failed, "A won link still needs a deadline")
        XCTAssertNil(client.lastConnectedAt)
        client.disconnect(); client.forget(host)
        await mac.stop()
    }

    func testControlSurfaceAcceptsTouchesAfterWelcomeAndReconnect() async throws {
        let mac = try TestMac()
        try await mac.start()
        let client = makeClient()
        let host = pairedHost(mac)
        let panel = PanelClient()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            ContentView().environmentObject(client).environmentObject(panel)
                .environmentObject(VoiceCapture()).environmentObject(ListenClient())
                .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer {
            panel.stop()
            window.isHidden = true
            window.rootViewController = nil
            client.disconnect()
            client.forget(host)
        }

        func trackpad(in view: UIView) -> TrackpadSurface? {
            if let pad = view as? TrackpadSurface { return pad }
            return view.subviews.lazy.compactMap { trackpad(in: $0) }.first
        }
        func acceptsTouches() -> Bool {
            window.layoutIfNeeded()
            guard let pad = trackpad(in: window), !pad.bounds.isEmpty else { return false }
            let point = pad.convert(CGPoint(x: pad.bounds.midX, y: pad.bounds.midY), to: window)
            return window.hitTest(point, with: nil) === pad
        }

        XCTAssertFalse(acceptsTouches(), "Controls must not accept touches before approval")
        client.connect(to: host)
        let firstWelcome = await waitUntil { acceptsTouches() }
        XCTAssertTrue(firstWelcome, "A welcome must enable the existing screen's UIKit touch surface")
        client.disconnect()
        let disabled = await waitUntil { !acceptsTouches() }
        XCTAssertTrue(disabled, "Disconnect must disable remote input")
        client.connect(to: host)
        let reconnected = await waitUntil { acceptsTouches() }
        XCTAssertTrue(reconnected, "Reconnection must enable input again without rebuilding the screen")
        await mac.stop()
    }

    // MARK: - Moving to a better route

    /// Connected over a slow relay on "cellular", then the phone joins the
    /// Mac's network: the session moves to the LAN by itself, without ever
    /// dropping, and the relay is let go.
    func testARelaySessionMovesToTheLANWhenTheNetworkChanges() async throws {
        let mac = try TestMac()
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.15)
        try await relay.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        defer { client.disconnect(); client.forget(host); relay.stop() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let onRelay = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(onRelay)
        XCTAssertEqual(client.session?.reach, .relay)
        // Measure the relay so there is something to compare against.
        let measured = await waitUntil(timeout: 5) { (client.linkStats.roundTrips.count) >= 2 }
        XCTAssertTrue(measured)

        var dropped = false
        let moving = Date()
        client.networkPathChanged(satisfied: true, signature: "wifi fixture", cellularOnly: false)
        let moved = await waitUntil(timeout: 12) {
            if !client.state.isConnected { dropped = true }
            return client.session?.reach == .local
        }
        XCTAssertTrue(moved, "a session on the relay must move to the LAN once the LAN can reach the Mac")
        XCTAssertFalse(dropped, "the move is make-before-break: the session never goes down")
        XCTAssertEqual(client.linkStats.lastMove?.hasPrefix("relay → local network"), true, "\(String(describing: client.linkStats.lastMove))")
        print("relay → LAN move took \(Int(Date().timeIntervalSince(moving) * 1000)) ms; \(client.linkStats.lastMove ?? "")")
        await mac.stop()
    }

    /// Clicks never straddle two sockets: while a button is held the session
    /// stays where it is, and every press and release reaches the Mac once.
    func testAMoveWaitsForHeldButtonsAndDeliversEachClickOnce() async throws {
        let mac = try TestMac()
        let record = MessageRecording()
        mac.onMessage = { connection, message in record.append(ObjectIdentifier(connection), message) }
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.1)
        try await relay.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        defer { client.disconnect(); client.forget(host); relay.stop() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let connected = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(connected)
        _ = await waitUntil(timeout: 5) { client.linkStats.roundTrips.count >= 2 }

        client.send(.click(button: .left, phase: .down, clickCount: 1))
        client.networkPathChanged(satisfied: true, signature: "wifi fixture", cellularOnly: false)
        // Dragging: moves keep flowing while the button is down.
        for _ in 0..<40 {
            client.sendMove(dx: 1, dy: 0)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(client.session?.reach, .relay, "no switch while a button is held")
        client.send(.click(button: .left, phase: .up, clickCount: 1))
        let moved = await waitUntil(timeout: 20) { client.session?.reach == .local }
        XCTAssertTrue(moved)
        client.send(.click(button: .left, phase: .click, clickCount: 1))
        let arrived = await waitUntil(timeout: 5) { record.clicks.count == 3 }
        XCTAssertTrue(arrived, "\(record.clicks)")
        let clicks = record.clicks
        XCTAssertEqual(clicks.map(\.phase), [.down, .up, .click], "each click once, in order")
        XCTAssertEqual(clicks[0].connection, clicks[1].connection, "a press and its release share a socket")
        XCTAssertNotEqual(clicks[1].connection, clicks[2].connection, "input after the move uses the new socket")
        await mac.stop()
    }

    /// Wi-Fi again after a relay success: the relay does not jump the queue,
    /// so the LAN answers and the relay is never even dialled.
    func testOnWiFiARelaySuccessIsNotPromotedAheadOfTheLAN() async throws {
        let mac = try TestMac()
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.15)
        try await relay.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        defer { client.disconnect(); client.forget(host); relay.stop() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let onRelay = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(onRelay)
        XCTAssertEqual(client.session?.reach, .relay)
        client.disconnect()
        let dialled = relay.accepted
        client.networkPathChanged(satisfied: true, signature: "wifi fixture", cellularOnly: false)
        client.connect(to: host)
        let back = await waitUntil(timeout: 10) { client.state.isConnected }
        XCTAssertTrue(back)
        XCTAssertEqual(client.session?.reach, .local)
        XCTAssertEqual(relay.accepted, dialled, "the relay must not be dialled ahead of a LAN that answers")
        print("Wi-Fi reconnect after a relay session: TLS \(client.linkStats.tlsMillis ?? -1) ms, welcome \(client.linkStats.welcomeMillis ?? -1) ms")
        await mac.stop()
    }

    /// The mirror follows the session to its new route without going dark:
    /// the new socket says hello and takes over with its first frame.
    func testTheMirrorFollowsTheSessionToItsNewRoute() async throws {
        let mac = try TestMac()
        let views = MessageRecording()
        mac.onViewHello = { connection in
            let index = views.noteViewer(ObjectIdentifier(connection))
            let bytes = try! ViewFrameWriter.encode(.state("viewer \(index)", title: "Test window"), payload: Data())
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.1)
        try await relay.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        let panel = PanelClient()
        defer { panel.stop(); client.disconnect(); client.forget(host); relay.stop() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let connected = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(connected)
        panel.start(control: client)
        let first = await waitUntil(timeout: 10) { panel.message == "viewer 1" }
        XCTAssertTrue(first)
        _ = await waitUntil(timeout: 5) { client.linkStats.roundTrips.count >= 2 }
        client.networkPathChanged(satisfied: true, signature: "wifi fixture", cellularOnly: false)
        var dark = false
        let followed = await waitUntil(timeout: 15) {
            if !panel.isConnected { dark = true }
            return client.session?.reach == .local && panel.message == "viewer 2"
        }
        XCTAssertTrue(followed, "the mirror must move to the new route: \(String(describing: panel.message))")
        XCTAssertFalse(dark, "the old mirror socket stays up until the new one has a frame")
        await mac.stop()
    }

    /// The direct path end to end, as on 5G: the session comes up through a
    /// slow relay, the two ends trade addresses inside it, punch, open a KCP
    /// tunnel, and the session — mirror included — moves onto it without ever
    /// going down. On loopback here; on 2026-10-05 the real one measured 81 ms
    /// against the relay's 924.
    func testASessionOnTheRelayMovesOntoAPunchedDirectTunnel() async throws {
        DirectProbe.addressOverride = "::1"
        defer { DirectProbe.addressOverride = nil }
        let mac = try TestMac()
        let tunnels = TunnelHolder()
        mac.onMessage = { connection, message in
            guard case .directOffer(let peer) = message,
                  let secret = TrustTransport.exporter(of: connection, label: DirectPacket.exporterLabel),
                  let probe = DirectProbe(secret: secret, address: "::1") else { return }
            mac.send(.directAnswer(probe.local, note: nil), on: connection)
            let port = mac.port
            probe.punch(peer: peer) { fd, _, _ in
                guard let fd else { return }
                let tunnel = DirectTunnel(socket: fd, secret: secret, side: .acceptor(port: port))
                tunnels.hold(tunnel)
                tunnel.start()
            }
            tunnels.hold(probe)
        }
        let views = MessageRecording()
        mac.onViewHello = { connection in
            let index = views.noteViewer(ObjectIdentifier(connection))
            let bytes = try! ViewFrameWriter.encode(.state("viewer \(index)", title: "Test window"), payload: Data())
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.15)
        try await relay.start()
        // An address that takes the connection and never answers — the Mac's
        // public IPv6 behind its router, as on 5G — so a look is still waiting
        // on it when the tunnel opens. On 2026-10-05 that delayed the move by
        // twenty seconds.
        let silent = try NWListener(using: .tcp, on: .any)
        silent.newConnectionHandler = { $0.start(queue: .global()) }
        silent.start(queue: .global())
        let silentUp = await waitUntil { (silent.port?.rawValue ?? 0) != 0 }
        XCTAssertTrue(silentUp)
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: silent.port!.rawValue, reach: .internet6, via: "blocked IPv6"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        let panel = PanelClient()
        defer { panel.stop(); client.disconnect(); client.forget(host); relay.stop(); silent.cancel(); tunnels.closeAll() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let onRelay = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(onRelay)
        XCTAssertEqual(client.session?.reach, .relay)
        var dropped = false
        // The direct path is asked for alongside hello, so the move follows
        // welcome by a punch and a few round trips on the tunnel — not by
        // seconds, and not by the look still waiting on the silent address.
        let connectedAt = Date()
        let moved = await waitUntil(timeout: 1.5) {
            if !client.state.isConnected { dropped = true }
            return client.connectionRouteDescription == "Direct IPv6"
        }
        print("connected → on the direct path: \(Int(Date().timeIntervalSince(connectedAt) * 1000)) ms")
        XCTAssertTrue(moved, "route: \(client.connectionRouteDescription), direct: \(client.linkStats.direct ?? "-")")
        XCTAssertFalse(dropped, "the move is make-before-break")
        // The mirror over the tunnel. (Following a move is covered on the LAN
        // by testTheMirrorFollowsTheSessionToItsNewRoute; here the move comes
        // before the mirror would have started.)
        panel.start(control: client)
        let mirrored = await waitUntil(timeout: 10) { panel.message?.hasPrefix("viewer") == true && panel.isConnected }
        XCTAssertTrue(mirrored, "the mirror runs over the tunnel")
        // And the session works there: a ping answered over the tunnel.
        let measured = client.linkStats.roundTrips.count
        let pinged = await waitUntil(timeout: 8) { client.linkStats.roundTrips.count > measured }
        XCTAssertTrue(pinged)
        print("relay → direct tunnel: \(client.linkStats.lastMove ?? "-"); \(client.linkStats.direct ?? "-")")
        await mac.stop()
    }

    /// No direct path (the probe is declined, as with no IPv6): the session
    /// still leaves the TCP relay for the relay's UDP, where a lost packet is
    /// a resend instead of a stall, and stays connected throughout.
    func testWithoutADirectPathTheSessionMovesToTheRelaysUDP() async throws {
        let mac = try TestMac()
        let pairs = try UDPPairRelay()
        let tunnels = TunnelHolder()
        mac.onMessage = { connection, message in
            switch message {
            case .directOffer:
                mac.send(.directAnswer(nil, note: "no IPv6 here"), on: connection)
            case .relayTunnelRequest:
                guard let secret = TrustTransport.exporter(of: connection, label: RelayDatagramGrant.exporterLabel) else { return }
                let grant = RelayDatagramGrant(host: "127.0.0.1", port: pairs.port, token: RelayDatagramGrant.newToken())
                guard let fd = DirectSocket.connected(to: grant.host, port: grant.port),
                      let framing = grant.framing(asMac: true) else { return }
                let tunnel = DirectTunnel(socket: fd, secret: secret, side: .acceptor(port: mac.port),
                                          framing: framing, redundancy: .small(copies: 2, maxBytes: 300))
                tunnels.hold(tunnel)
                tunnel.start()
                mac.send(.relayTunnel(grant, note: nil), on: connection)
            default:
                break
            }
        }
        try await mac.start()
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 0.15)
        try await relay.start()
        let host = pairedHost(mac, at: [NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay")])
        let client = makeClient()
        defer { client.disconnect(); client.forget(host); relay.stop(); pairs.stop(); tunnels.closeAll() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let connected = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(connected)
        var dropped = false
        let moved = await waitUntil(timeout: 5) {
            if !client.state.isConnected { dropped = true }
            return client.connectionRouteDescription == "Relay (UDP)"
        }
        XCTAssertTrue(moved, "route: \(client.connectionRouteDescription), relay UDP: \(client.linkStats.relayUDP ?? "-")")
        XCTAssertFalse(dropped)
        let measured = client.linkStats.roundTrips.count
        let pinged = await waitUntil(timeout: 8) { client.linkStats.roundTrips.count > measured }
        XCTAssertTrue(pinged, "the session answers over the relay's UDP")
        print("TCP relay → relay UDP: \(client.linkStats.lastMove ?? "-")")
        await mac.stop()
    }

    /// The session moves while the mirror is still dialling the old route —
    /// what happened on 5G once the move became fast. The mirror must end up
    /// on the session's new route, not finish its old handshake and stay.
    func testAMirrorStillDialingFollowsTheSession() async throws {
        let mac = try TestMac()
        mac.onViewHello = { connection in
            let bytes = try! ViewFrameWriter.encode(.state("frame", title: "Test window"), payload: Data())
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
        try await mac.start()
        // A slow relay, so the mirror's handshake through it is still running
        // when the LAN answers.
        let relay = try SNIForwarder(to: mac.listener.port!, delay: 1.0)
        try await relay.start()
        let host = pairedHost(mac, at: [
            NimletCandidate(host: "127.0.0.1", port: mac.port, reach: .local, via: "test"),
            NimletCandidate(host: "127.0.0.1", port: relay.port, reach: .relay, via: "relay"),
        ])
        let client = makeClient()
        let panel = PanelClient()
        defer { panel.stop(); client.disconnect(); client.forget(host); relay.stop() }
        try await Task.sleep(for: .milliseconds(100))
        client.networkPathChanged(satisfied: true, signature: "cellular fixture", cellularOnly: true)
        client.connect(to: host)
        let connected = await waitUntil(timeout: 20) { client.state.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(client.session?.reach, .relay)
        panel.start(control: client)
        client.networkPathChanged(satisfied: true, signature: "wifi fixture", cellularOnly: false)
        // Promptly: without the fix the mirror got there only after its own
        // 8 s handshake timeout, and on a relay that does answer, never.
        let aligned = await waitUntil(timeout: 4) {
            client.session?.reach == .local && panel.isConnected && panel.mirrorEndpoint == client.session?.endpoint
        }
        XCTAssertTrue(aligned, "mirror \(String(describing: panel.mirrorEndpoint)), session \(String(describing: client.session?.endpoint))")
        await mac.stop()
    }

    /// Every batch of video read is acknowledged with its highest sequence,
    /// which is what the Mac's in-flight window and queue-delay signal read.
    func testThePhoneAcknowledgesVideoFramesBySequence() async throws {
        let mac = try TestMac()
        let acks = MessageRecording()
        mac.onMessage = { _, message in
            if case .viewAck(let sequence) = message { acks.noteAck(sequence) }
        }
        let sent = MessageRecording()
        mac.onViewHello = { connection in
            // Once: a viewer re-sends its hello whenever its size settles.
            guard sent.noteViewer(ObjectIdentifier(connection)) == 1, sent.acks.isEmpty else { return }
            sent.noteAck(0)
            for sequence in [5, 6, 7] {
                var frame = ViewFrame(kind: .video, title: "Test window", captureTime: Instrumentation.now())
                frame.width = 320; frame.height = 200; frame.sequence = sequence
                connection.send(content: try! ViewFrameWriter.encode(frame, payload: Data()), completion: .contentProcessed { _ in })
            }
        }
        try await mac.start()
        let (client, host) = await connectedClient(to: mac)
        let panel = PanelClient()
        defer { panel.stop(); client.disconnect(); client.forget(host) }
        panel.start(control: client)
        let acknowledged = await waitUntil(timeout: 10) { acks.acks.last == 7 }
        XCTAssertTrue(acknowledged, "\(acks.acks)")
        XCTAssertEqual(acks.acks, acks.acks.sorted(), "acknowledgements only ever move forward")
        await mac.stop()
    }
}

/// A stand-in for the relay's UDP side: the same `NU1 | role | token` header,
/// forwarding each payload to the other role's last address.
private final class UDPPairRelay: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "udp-pair-relay")
    private var source: DispatchSourceRead?
    private var ends: [String: [UInt8: sockaddr_in]] = [:]
    let port: UInt16

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        fd = socketFD
        port = UInt16(bigEndian: bound.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.resume()
        self.source = source
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 20, buffer[0] == 0x4E, buffer[1] == 0x55, buffer[2] == 0x31 else { return }
        let role = buffer[3]
        let token = Data(buffer[4..<20]).base64EncodedString()
        ends[token, default: [:]][role] = from
        guard var other = ends[token]?[role == 0x4D ? 0x50 : 0x4D] else { return }
        let payload = Array(buffer[20..<count])
        _ = withUnsafePointer(to: &other) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    func stop() {
        source?.cancel()
        close(fd)
    }
}

/// Keeps the test Mac's probes and tunnels alive for the length of a test.
private final class TunnelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject] = []
    func hold(_ object: AnyObject) { lock.withLock { objects.append(object) } }
    func closeAll() { lock.withLock { objects.compactMap { $0 as? DirectTunnel }.forEach { $0.close() } } }
}

/// What a test Mac heard, from which socket. Locked: the fixture's queue
/// writes, the test reads.
private final class MessageRecording: @unchecked Sendable {
    struct Click: Equatable { let connection: ObjectIdentifier; let phase: ClickPhase }
    private let lock = NSLock()
    private var recordedClicks: [Click] = []
    private var viewers: [ObjectIdentifier] = []
    private var recordedAcks: [Int] = []
    var clicks: [Click] { lock.withLock { recordedClicks } }
    var acks: [Int] { lock.withLock { recordedAcks } }
    func append(_ connection: ObjectIdentifier, _ message: ClientMessage) {
        guard case .click(_, let phase, _) = message else { return }
        lock.withLock { recordedClicks.append(Click(connection: connection, phase: phase)) }
    }
    /// Numbers each viewer socket the first time it says hello.
    func noteViewer(_ connection: ObjectIdentifier) -> Int {
        lock.withLock {
            if let index = viewers.firstIndex(of: connection) { return index + 1 }
            viewers.append(connection)
            return viewers.count
        }
    }
    func noteAck(_ sequence: Int) { lock.withLock { recordedAcks.append(sequence) } }
}

/// A stand-in for the connect relay: forwards every connection to one port,
/// unread, and records the server name each ClientHello asked for.
private final class SNIForwarder: @unchecked Sendable {
    let listener: NWListener
    let target: NWEndpoint.Port
    private let queue = DispatchQueue(label: "sni-forwarder")
    private let lock = NSLock()
    private var names: [String] = []
    private var protocols: [String] = []
    private var links: [NWConnection] = []
    /// One-way delay added to every chunk, each direction: a relay across an
    /// ocean, on loopback.
    let delay: TimeInterval
    private var acceptedCount = 0
    /// Phone connections this relay has been asked to carry.
    var accepted: Int { lock.withLock { acceptedCount } }
    var serverNames: [String] { lock.withLock { names } }
    var routeProtocols: [String] { lock.withLock { protocols } }
    var port: UInt16 { listener.port!.rawValue }

    init(to target: NWEndpoint.Port, delay: TimeInterval = 0) throws {
        self.target = target
        self.delay = delay
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [unowned self] phone in
                let mac = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
                lock.withLock { links += [phone, mac]; acceptedCount += 1 }
                phone.start(queue: queue)
                mac.start(queue: queue)
                phone.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] data, _, _, _ in
                    guard let data else { return }
                    let ascii = String(decoding: data.map { (32...126).contains($0) ? $0 : 32 }, as: UTF8.self)
                    if let name = ascii.split(separator: " ").first(where: { $0.hasSuffix(".nimlet") }) {
                        lock.withLock { names.append(String(name.suffix(47))) }
                    }
                    if let range = ascii.range(of: "nimlet-[0-9a-f]{40}", options: .regularExpression) {
                        lock.withLock { protocols.append(String(ascii[range])) }
                    }
                    forward(data, to: mac)
                    pump(phone, mac); pump(mac, phone)
                }
            }
            listener.start(queue: queue)
        }
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.forward(data, to: to) }
            if done || error != nil {
                self.queue.asyncAfter(deadline: .now() + self.delay) { to.cancel() }
                return
            }
            self.pump(from, to)
        }
    }

    /// One serial queue and one delay for every chunk, so order is kept.
    private func forward(_ data: Data, to: NWConnection) {
        guard delay > 0 else { to.send(content: data, completion: .contentProcessed { _ in }); return }
        queue.asyncAfter(deadline: .now() + delay) { to.send(content: data, completion: .contentProcessed { _ in }) }
    }

    func stop() {
        listener.cancel()
        lock.withLock { links.forEach { $0.cancel() } }
    }
}

private final class AppCommandRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [AppCommand] = []
    var count: Int { lock.withLock { commands.count } }
    func append(_ command: AppCommand) { lock.withLock { commands.append(command) } }
}
