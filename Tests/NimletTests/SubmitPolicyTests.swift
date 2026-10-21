import XCTest

/// Which apps a fresh target presses Return for.
///
/// The rule is small and the consequence of getting it wrong is a dictated
/// sentence run as a shell command, so it is pinned here rather than left to
/// whichever table happens to list a terminal this year.
final class SubmitPolicyTests: XCTestCase {

    func testTerminalsNeverPressReturnByDefault() {
        for bundleID in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                         "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty"] {
            XCTAssertFalse(NimletTarget.pressesReturnByDefault(bundleID: bundleID), bundleID)
            var target = NimletTarget(name: "T", kind: .app, bundleID: bundleID)
            target.applyDefaultSubmitPolicy()
            XCTAssertFalse(target.submitOnSend, bundleID)
            XCTAssertFalse(target.allowAutoSubmit, "\(bundleID): the policy field is the one that matters")
        }
    }

    func testAChannelBuildOfATerminalCountsAsThatTerminal() {
        XCTAssertFalse(NimletTarget.pressesReturnByDefault(bundleID: "com.googlecode.iterm2.beta"))
    }

    func testChatAppsAndEditorsKeepReturn() {
        for bundleID in ["com.anthropic.claudefordesktop", "com.openai.chat", "com.microsoft.VSCode",
                         "com.apple.Safari", "com.apple.TextEdit", "some.unknown.app"] {
            XCTAssertTrue(NimletTarget.pressesReturnByDefault(bundleID: bundleID), bundleID)
            var target = NimletTarget(name: "A", kind: .app, bundleID: bundleID)
            target.applyDefaultSubmitPolicy()
            XCTAssertTrue(target.submitOnSend, bundleID)
            XCTAssertTrue(target.allowAutoSubmit, bundleID)
        }
    }

    func testOnlyAppTargetsAreTouched() {
        var pane = NimletTarget(name: "shell", kind: .tmux, tmuxTarget: "%1")
        pane.applyDefaultSubmitPolicy()
        XCTAssertTrue(pane.submitOnSend, "pane policy is decided from the pane's command, not here")
    }

    func testAPhoneOnAnotherVersionIsRefusedWithARecognisableMessage() {
        let refusal = NimletProtocol.versionRefusal(clientVersion: NimletProtocol.version - 1)
        XCTAssertEqual(ConnectionRejection(message: refusal), .versionMismatch)
        XCTAssertTrue(refusal.contains("on this phone"), "the phone screen reads which end to update from this phrase")
    }
}
