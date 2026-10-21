import XCTest

final class AppManagementTests: XCTestCase {
    private let ref = AppReference(bundleID: "org.nimlet.QA", applicationPath: "/Applications/NimletDockQA.app")
    private func identity(session: String = "host", instance: String = "one", started: Int64? = 100) -> AppInstanceIdentity {
        AppInstanceIdentity(hostSessionID: session, instanceID: instance, processID: 123, app: ref, launchEpochMillis: started)
    }
    private func command(id: String = "request", window: UInt32 = 4) -> AppCommand {
        AppCommand(id: id, hostSessionID: "host", action: .closeWindow, app: ref, identity: identity(), windowID: window)
    }

    func testProcessIdentityRejectsReusedPIDAndAllowsUninterruptedHostRestart() {
        XCTAssertFalse(identity().identifiesSameProcess(as: identity(instance: "restarted", started: 200)))
        XCTAssertTrue(identity().identifiesSameProcess(as: identity(session: "new-host", instance: "new-token")))
        XCTAssertFalse(identity().identifiesSameProcess(as: identity(session: "new-host", instance: "new-token", started: 200)))
        XCTAssertFalse(identity(started: nil).identifiesSameProcess(as: identity(session: "new-host", started: nil)))
        var copy = identity(); copy.app.applicationPath = "/Applications/OtherCopy.app"
        XCTAssertFalse(identity().identifiesSameProcess(as: copy))
    }

    func testRepeatedCloseReturnsReceiptWithoutExecutionAndCannotChangeWindow() {
        var ledger = AppCommandLedger()
        guard case .start = ledger.begin(command(), deviceID: "phone") else { return XCTFail("first request must start") }
        guard case .existing(let pending) = ledger.begin(command(), deviceID: "phone") else { return XCTFail("duplicate must not execute") }
        XCTAssertEqual(pending.phase, .working)
        let result = AppCommandResult(requestID: "request", phase: .succeeded, message: "closed")
        ledger.finish(result, deviceID: "phone")
        guard case .existing(let receipt) = ledger.begin(command(), deviceID: "phone") else { return XCTFail("reconnect duplicate must return result") }
        XCTAssertEqual(receipt, result)
        guard case .conflict = ledger.begin(command(window: 8), deviceID: "phone") else { return XCTFail("same id cannot address another window") }
        guard case .start = ledger.begin(command(), deviceID: "other-phone") else { return XCTFail("request ids are scoped by device") }
    }

    func testPendingCommandsCannotBeEvictedAndInFlightWorkIsBounded() {
        var ledger = AppCommandLedger(limit: 2)
        for index in 0..<16 {
            guard case .start = ledger.begin(command(id: "\(index)"), deviceID: "phone") else { return XCTFail("up to 16 in flight") }
        }
        guard case .busy = ledger.begin(command(id: "17"), deviceID: "phone") else { return XCTFail("bound work") }
        guard case .existing = ledger.begin(command(id: "0"), deviceID: "phone") else { return XCTFail("never evict in-flight close") }
    }

    func testRetiredRequestCannotExecuteAfterReceiptEviction() {
        var ledger = AppCommandLedger(limit: 1)
        _ = ledger.begin(command(id: "old"), deviceID: "phone")
        ledger.finish(AppCommandResult(requestID: "old", phase: .succeeded, message: "closed"), deviceID: "phone")
        _ = ledger.begin(command(id: "new"), deviceID: "phone")
        guard case .existing(let receipt) = ledger.begin(command(id: "old"), deviceID: "phone") else { return XCTFail("never re-execute evicted destructive command") }
        XCTAssertEqual(receipt.phase, .unconfirmed)
    }

    func testWindowChunksRetainInstanceIdentityAndCompleteWindowSet() throws {
        let windows = (0..<30).map { MacWindow(id: UInt32($0 + 1), title: "Untitled", appName: "QA", preview: Data(repeating: 3, count: 20000), canClose: true) }
        let chunks = WindowListPayload.chunked(windows, targetID: "qa", appIdentity: identity())
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap(\.windows).map(\.id), windows.map(\.id))
        for chunk in chunks {
            let line = try NimletCoder.line(HostMessage.windows(chunk))
            XCTAssertLessThan(line.count, 1 << 20)
            guard case .windows(let read) = try NimletCoder.decode(HostMessage.self, from: Data(line.dropLast())) else { return XCTFail() }
            XCTAssertEqual(read.appIdentity, identity())
        }
    }

    func testInstalledCopiesRemainDistinctAndLegacyTargetsStillDecode() throws {
        let first = MacApp(bundleID: ref.bundleID, name: "QA", applicationPath: ref.applicationPath)
        let second = MacApp(bundleID: ref.bundleID, name: "QA", applicationPath: "/Users/me/Applications/QA.app")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.appReference.matches(second.appReference))
        XCTAssertTrue(AppReference(bundleID: ref.bundleID.uppercased()).matches(first.appReference))
        let legacy = try NimletCoder.decode(NimletTarget.self, from: Data("{\"id\":\"a\",\"name\":\"old\",\"kind\":\"app\",\"bundleID\":\"org.nimlet.QA\",\"pinnedWindowID\":8}".utf8))
        XCTAssertEqual(legacy.id, "a"); XCTAssertEqual(legacy.pinnedWindowID, 8)
        XCTAssertNil(legacy.applicationPath); XCTAssertNil(legacy.pinnedAppIdentity)
        let status = HostStatus(hostName: "old", accessibilityGranted: true, injectionPaused: false, activeTargetID: nil, deviceApproved: true)
        XCTAssertNil(try NimletCoder.decode(HostStatus.self, from: NimletCoder.encode(status)).appManagementVersion)
    }

    func testCompleteRuntimeAndDirectoryHaveNoThirtyItemLimit() throws {
        let apps = (0..<80).map { index -> RunningMacApp in
            var id = identity(instance: "\(index)"); id.processID += Int32(index)
            return RunningMacApp(identity: id, name: "App \(index)", isActive: index == 0, isHidden: false)
        }
        let snapshot = AppRuntimeSnapshot(hostSessionID: "host", revision: 3, apps: apps)
        guard case .appState(let read) = try NimletCoder.decode(HostMessage.self, from: NimletCoder.encode(HostMessage.appState(snapshot))) else { return XCTFail() }
        XCTAssertEqual(read.apps.count, 80)
        let directory = (0..<300).map { MacApp(bundleID: "app.\($0)", name: "App \($0)", applicationPath: "/Applications/App\($0).app") }
        XCTAssertEqual(AppCatalogPayload.chunked(directory, purpose: .suggestions).flatMap(\.apps).count, 300)
    }
}
