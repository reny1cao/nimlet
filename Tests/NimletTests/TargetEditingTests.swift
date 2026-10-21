import XCTest

/// The phone can now change the Mac's target list. These cover the parts of
/// that which travel: what the wire carries, and what an older or partial
/// message decodes to.
final class TargetEditingTests: XCTestCase {

    func testEditingAndRemovalSurviveTheWire() throws {
        let target = NimletTarget(id: "t1", name: "shell", kind: .tmux,
                                tmuxTarget: "%2", submitOnSend: false,
                                allowAutoSubmit: false, symbol: "terminal")
        let line = try NimletCoder.line(ClientMessage.updateTarget(target))
        guard case .updateTarget(let round) = try NimletCoder.decode(ClientMessage.self,
                                                                   from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round, target)
        XCTAssertFalse(round.allowAutoSubmit, "the policy is the field that must never be lost")

        let removal = try NimletCoder.line(ClientMessage.removeTarget(id: "t1"))
        guard case .removeTarget(let id) = try NimletCoder.decode(ClientMessage.self,
                                                                from: removal.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(id, "t1")
    }

    func testAPaneListSurvivesTheWire() throws {
        let panes = [TmuxPane(id: "%3", spec: "api:0.1", command: "claude",
                              path: "/Users/someone/workspace/mice")]
        let line = try NimletCoder.line(HostMessage.panes(panes))
        guard case .panes(let round) = try NimletCoder.decode(HostMessage.self,
                                                            from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round, panes)
        XCTAssertEqual(round[0].shortPath, "workspace/mice",
                       "two components, so two checkouts of one project are told apart")
    }

    func testAShortPathIsNotPaddedOrTruncatedIntoSomethingElse() {
        XCTAssertEqual(TmuxPane(id: "%1", spec: "a:0.0", command: "zsh", path: "/").shortPath, "")
        XCTAssertEqual(TmuxPane(id: "%1", spec: "a:0.0", command: "zsh", path: "/tmp").shortPath, "tmp")
    }

    func testUnresolvedTargetIDsSurviveTheWire() throws {
        let status = HostStatus(hostName: "Mac", accessibilityGranted: true,
                                injectionPaused: false, activeTargetID: "t1",
                                deviceApproved: true, tmuxAvailable: true,
                                unresolvedTargetIDs: ["t7"])
        let line = try NimletCoder.line(HostMessage.status(status))
        guard case .status(let round) = try NimletCoder.decode(HostMessage.self,
                                                             from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round.unresolvedTargetIDs, ["t7"])
    }

    /// The phone's editor turns "never press Return" on by writing
    /// `allowAutoSubmit = false`, and has to turn the preference off with it —
    /// otherwise the target keeps a yes that cannot be honoured now and comes
    /// back to life the day the policy is lifted.
    func testAPolicyLockedTargetCarriesNoContradictoryPreference() {
        var target = NimletTarget(name: "shell", kind: .tmux, tmuxTarget: "%2",
                                submitOnSend: true, allowAutoSubmit: true)
        target.allowAutoSubmit = false
        target.submitOnSend = false
        XCTAssertFalse(target.submitOnSend)
        XCTAssertFalse(target.allowAutoSubmit)
    }
}
