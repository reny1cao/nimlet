import XCTest

@MainActor
final class ProFeatureAccessTests: XCTestCase {
    func testPublicBetaNeedsNoPurchaseOrRestore() async {
        let beta = ProStore(publicBetaAccess: true)
        XCTAssertTrue(beta.isPublicBeta)
        XCTAssertTrue(beta.hasPro)
        XCTAssertFalse(beta.hasLifetime)
        XCTAssertFalse(beta.hasSubscription)
        await beta.refresh()
        await beta.restore()
        await beta.complete(.success(.userCancelled))
        XCTAssertTrue(beta.hasPro)
        XCTAssertNil(beta.message)
        let client = NimletClient(proAccess: { beta.hasPro })
        XCTAssertTrue(client.requirePro())
        client.sendText("Beta input", to: ["sample"])
        XCTAssertFalse(client.showingPro)
    }
    func testEveryTextPathOffersProWithoutAnEntitlement() {
        let client = NimletClient(proAccess: { false })
        client.send(.text(TextPayload(text: "paste", targetID: "one")))
        XCTAssertTrue(client.showingPro)
        client.showingPro = false
        client.sendText("dictation or preset", to: ["one"])
        XCTAssertTrue(client.showingPro)
        client.showingPro = false
        client.send(.move(dx: 1, dy: 2))
        XCTAssertFalse(client.showingPro)
    }

    func testLockedStreamAndListeningCannotStart() {
        let client = NimletClient(proAccess: { false })
        let panel = PanelClient()
        panel.start(control: client)
        XCTAssertFalse(panel.isConnected)
        XCTAssertFalse(panel.isVideo)
        let audio = ListenClient()
        audio.turnOn(control: client)
        XCTAssertFalse(audio.isOn)
        XCTAssertTrue(client.showingPro)
    }

    func testPassiveQueriesDoNotInterruptFreeControls() {
        let client = NimletClient(proAccess: { false })
        client.send(.requestWindows(targetID: "a"))
        client.send(.requestPendingApprovals)
        XCTAssertFalse(client.showingPro)
        XCTAssertFalse(client.requirePro())
        XCTAssertTrue(client.showingPro)
    }
}
