import XCTest

final class PhoneDockTests: XCTestCase {
    private func app(_ id: String, bundle: String = "org.nimlet.QA", path: String? = "/Applications/QA.app", live: Bool = false) -> NimletTarget {
        NimletTarget(id: id, name: id, kind: .app, bundleID: bundle, applicationPath: path, isProvisional: live)
    }

    func testTerminalTargetsStayOutsideTheAppDock() {
        let targets = [NimletTarget(id: "cat", name: "cat (mice)", kind: .tmux), app("editor")]
        XCTAssertEqual(PhoneDockArrangement().visibleTargets(in: targets).map(\.id), ["editor"])
    }

    func testRemovedFavoriteDoesNotReturnAsARunningTile() throws {
        let original = app("favorite", path: nil)
        var layout = PhoneDockArrangement()
        layout.hide(try XCTUnwrap(original.appReference))
        // Mac removal changes both the target ID and the running-app path metadata.
        let running = app("provisional", live: true)
        let restored = try JSONDecoder().decode(PhoneDockArrangement.self, from: JSONEncoder().encode(layout))
        XCTAssertTrue(restored.visibleTargets(in: [running]).isEmpty)
        XCTAssertEqual([running].count, 1, "hiding must not alter the authoritative app list")
        layout.show(try XCTUnwrap(running.appReference))
        XCTAssertEqual(layout.visibleTargets(in: [running]).map(\.id), ["provisional"])
    }

    func testHideDistinguishesInstalledCopies() throws {
        let first = app("first")
        let second = app("second", path: "/Users/me/QA.app")
        var layout = PhoneDockArrangement()
        layout.hide(try XCTUnwrap(first.appReference))
        XCTAssertEqual(layout.visibleTargets(in: [first, second]).map(\.id), ["second"])
    }

    func testLiveAppOrderSurvivesReconnectAndNewTargetIDs() throws {
        let first = app("a", bundle: "org.nimlet.A")
        let second = app("b", bundle: "org.nimlet.B", live: true)
        let layout = PhoneDockArrangement(order: [PhoneDockArrangement.key(for: second), PhoneDockArrangement.key(for: first)])
        let restored = try JSONDecoder().decode(PhoneDockArrangement.self, from: JSONEncoder().encode(layout))
        let promoted = app("promoted-b", bundle: "org.nimlet.B")
        let new = app("c", bundle: "org.nimlet.C", live: true)
        XCTAssertEqual(restored.visibleTargets(in: [first, new, promoted]).map(\.id), ["promoted-b", "a", "c"])
    }
}
