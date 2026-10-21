import XCTest

/// Every wire message, encoded and framed the way the apps do it and read back
/// the way the apps read it. A case that only one end knows how to spell is
/// indistinguishable, at runtime, from a dropped connection.
final class NimletCoderTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        var framer = LineFramer()
        let framed = framer.append(try NimletCoder.line(value))
        XCTAssertEqual(framed.count, 1, "one message must frame as exactly one line")
        return try NimletCoder.decode(T.self, from: framed[0])
    }

    private func sampleTarget() -> NimletTarget {
        NimletTarget(id: "t-1",
                   name: "Claude",
                   kind: .tmux,
                   bundleID: nil,
                   tmuxTarget: "%3",
                   submitOnSend: true,
                   allowAutoSubmit: false,
                   symbol: "sparkles")
    }

    private func sampleStatus() -> HostStatus {
        HostStatus(hostName: "Studio",
                   accessibilityGranted: true,
                   injectionPaused: false,
                   activeTargetID: "t-1",
                   deviceApproved: true,
                   tmuxAvailable: true)
    }

    func testAnEncodedLineEndsInExactlyOneNewlineAndContainsNoOthers() throws {
        let data = try NimletCoder.line(ClientMessage.text(TextPayload(text: "a\nb\nc")))
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.dropLast().filter { $0 == 0x0A }.count, 0,
                       "a newline inside a payload must be escaped, not emitted raw")
    }

    func testDecodingGarbageThrowsRatherThanReturningSomethingEmpty() {
        XCTAssertThrowsError(try NimletCoder.decode(ClientMessage.self, from: Data("not json".utf8)))
    }

    // MARK: phone -> Mac

    func testAHelloRoundTripsWithItsVersionNameAndDeviceID() throws {
        let sent = ClientMessage.hello(HelloPayload(deviceName: "Rey's iPhone", deviceID: "dev-abc"))
        guard case .hello(let payload) = try roundTrip(sent) else {
            return XCTFail("a hello must decode as a hello")
        }
        XCTAssertEqual(payload.protocolVersion, NimletProtocol.version)
        XCTAssertEqual(payload.deviceName, "Rey's iPhone")
        XCTAssertEqual(payload.deviceID, "dev-abc")
    }

    func testAMoveRoundTripsItsSignedFractionalDeltas() throws {
        guard case .move(let dx, let dy) = try roundTrip(ClientMessage.move(dx: -12.5, dy: 0.25)) else {
            return XCTFail("a move must decode as a move")
        }
        XCTAssertEqual(dx, -12.5)
        XCTAssertEqual(dy, 0.25)
    }

    func testAScrollRoundTripsItsDeltas() throws {
        guard case .scroll(let dx, let dy) = try roundTrip(ClientMessage.scroll(dx: 0, dy: -3.75)) else {
            return XCTFail("a scroll must decode as a scroll")
        }
        XCTAssertEqual(dx, 0)
        XCTAssertEqual(dy, -3.75)
    }

    /// Every one of the four, because they are only useful in pairs: a `began`
    /// that decodes and an `ended` that does not is a Mac stuck mid-gesture.
    func testEveryScrollPhaseRoundTrips() throws {
        for sent in [ScrollGesturePhase.began, .ended, .momentumBegan, .momentumEnded] {
            guard case .scrollPhase(let got) = try roundTrip(ClientMessage.scrollPhase(sent)) else {
                return XCTFail("\(sent) must decode as a scroll phase")
            }
            XCTAssertEqual(got, sent)
        }
    }

    /// The names go on the wire, so renaming a case renames a message. Pinned
    /// here rather than left to whoever next tidies the enum.
    func testTheScrollPhaseNamesAreTheOnesOnTheWire() {
        XCTAssertEqual(ScrollGesturePhase.began.rawValue, "began")
        XCTAssertEqual(ScrollGesturePhase.ended.rawValue, "ended")
        XCTAssertEqual(ScrollGesturePhase.momentumBegan.rawValue, "momentumBegan")
        XCTAssertEqual(ScrollGesturePhase.momentumEnded.rawValue, "momentumEnded")
    }

    func testAClickRoundTripsItsButtonPhaseAndCount() throws {
        let sent = ClientMessage.click(button: .right, phase: .down, clickCount: 2)
        guard case .click(let button, let phase, let count) = try roundTrip(sent) else {
            return XCTFail("a click must decode as a click")
        }
        XCTAssertEqual(button, .right)
        XCTAssertEqual(phase, .down)
        XCTAssertEqual(count, 2)
    }

    func testATextPayloadRoundTripsItsTargetAndSubmitOverride() throws {
        let sent = ClientMessage.text(TextPayload(text: "summarise the diff",
                                                  targetID: "t-1",
                                                  submit: false))
        guard case .text(let payload) = try roundTrip(sent) else {
            return XCTFail("text must decode as text")
        }
        XCTAssertEqual(payload.text, "summarise the diff")
        XCTAssertEqual(payload.targetID, "t-1")
        XCTAssertEqual(payload.submit, false)
    }

    func testAnAbsentSubmitOverrideStaysAbsentRatherThanBecomingFalse() throws {
        guard case .text(let payload) = try roundTrip(ClientMessage.text(TextPayload(text: "hi"))) else {
            return XCTFail("text must decode as text")
        }
        XCTAssertNil(payload.targetID)
        XCTAssertNil(payload.submit, "nil means defer to the target; false means do not submit")
    }

    func testTextSurvivesNewlinesEmojiAndQuotes() throws {
        let awkward = "line one\n\"quoted\" 🐭\ttabbed\\escaped"
        guard case .text(let payload) = try roundTrip(ClientMessage.text(TextPayload(text: awkward))) else {
            return XCTFail("text must decode as text")
        }
        XCTAssertEqual(payload.text, awkward)
    }

    func testAFocusRoundTripsItsTargetID() throws {
        guard case .focus(let targetID) = try roundTrip(ClientMessage.focus(targetID: "t-9")) else {
            return XCTFail("a focus must decode as a focus")
        }
        XCTAssertEqual(targetID, "t-9")
    }

    func testAKeyRoundTripsItsChordAndItsTarget() throws {
        let sent = ClientMessage.key(KeyPayload(chord: KeyChord("c", control: true),
                                                targetID: "t-3"))
        guard case .key(let payload) = try roundTrip(sent) else {
            return XCTFail("a key must decode as a key")
        }
        XCTAssertEqual(payload.chord, KeyChord("c", control: true))
        XCTAssertEqual(payload.targetID, "t-3")
    }

    func testAVocabularyRequestRoundTripsItsTargetID() throws {
        guard case .requestVocabulary(let targetID) = try roundTrip(ClientMessage.requestVocabulary(targetID: "t-2")) else {
            return XCTFail("a vocabulary request must decode as one")
        }
        XCTAssertEqual(targetID, "t-2")
    }

    func testAnAgentEventFromAClientRoundTripsWhole() throws {
        let event = AgentEvent(targetID: "t-1", kind: .waiting,
                               atEpochMillis: 1_771_000_000_123, note: "needs a decision")
        guard case .agentEvent(let decoded) = try roundTrip(ClientMessage.agentEvent(event)) else {
            return XCTFail("an agent event must decode as one")
        }
        XCTAssertEqual(decoded, event)
    }

    func testAPingRoundTripsANonceAtTheTopOfTheUInt64Range() throws {
        guard case .ping(let nonce) = try roundTrip(ClientMessage.ping(nonce: UInt64.max)) else {
            return XCTFail("a ping must decode as a ping")
        }
        XCTAssertEqual(nonce, UInt64.max)
    }

    // MARK: Mac -> phone

    func testAWelcomeRoundTripsBothItsStatusAndItsTargets() throws {
        let sent = HostMessage.welcome(status: sampleStatus(), targets: [sampleTarget()])
        guard case .welcome(let status, let targets) = try roundTrip(sent) else {
            return XCTFail("a welcome must decode as a welcome")
        }
        XCTAssertEqual(status, sampleStatus())
        XCTAssertEqual(targets, [sampleTarget()])
    }

    func testAStatusRoundTripsIncludingApprovalAndTmuxAvailability() throws {
        guard case .status(let status) = try roundTrip(HostMessage.status(sampleStatus())) else {
            return XCTFail("a status must decode as a status")
        }
        XCTAssertEqual(status, sampleStatus())
        XCTAssertTrue(status.deviceApproved)
        XCTAssertTrue(status.tmuxAvailable)
    }

    func testATargetListRoundTripsAndKeepsAllowAutoSubmitFalse() throws {
        guard case .targets(let targets) = try roundTrip(HostMessage.targets([sampleTarget()])) else {
            return XCTFail("targets must decode as targets")
        }
        XCTAssertEqual(targets.count, 1)
        XCTAssertFalse(targets[0].allowAutoSubmit, "the no-auto-submit policy must survive the wire")
        XCTAssertTrue(targets[0].hasStableTmuxID)
    }

    func testAnEmptyTargetListRoundTripsAsAnEmptyList() throws {
        guard case .targets(let targets) = try roundTrip(HostMessage.targets([])) else {
            return XCTFail("targets must decode as targets")
        }
        XCTAssertTrue(targets.isEmpty)
    }

    func testAToastRoundTripsItsText() throws {
        guard case .toast(let text) = try roundTrip(HostMessage.toast("Sent 14 words to Claude")) else {
            return XCTFail("a toast must decode as a toast")
        }
        XCTAssertEqual(text, "Sent 14 words to Claude")
    }

    func testAnErrorRoundTripsItsText() throws {
        guard case .error(let text) = try roundTrip(HostMessage.error("tmux pane %3 is gone")) else {
            return XCTFail("an error must decode as an error")
        }
        XCTAssertEqual(text, "tmux pane %3 is gone")
    }

    func testADeliveryReceiptRoundTripsWholeIncludingAFailedDelivery() throws {
        let receipt = DeliveryReceipt(ok: false, targetID: "t-1", targetName: "Claude",
                                      characters: 0, submitted: false,
                                      message: "Accessibility permission is missing")
        guard case .delivered(let decoded) = try roundTrip(HostMessage.delivered(receipt)) else {
            return XCTFail("a receipt must decode as a receipt")
        }
        XCTAssertEqual(decoded, receipt)
    }

    func testAReceiptForAnUnknownTargetKeepsItsNilTargetID() throws {
        let receipt = DeliveryReceipt(ok: true, targetID: nil, targetName: "Frontmost",
                                      characters: 18, submitted: true, message: "Sent")
        guard case .delivered(let decoded) = try roundTrip(HostMessage.delivered(receipt)) else {
            return XCTFail("a receipt must decode as a receipt")
        }
        XCTAssertNil(decoded.targetID)
        XCTAssertEqual(decoded, receipt)
    }

    func testAnAgentEventFromTheHostRoundTripsWithoutANote() throws {
        let event = AgentEvent(targetID: "t-4", kind: .failed, atEpochMillis: 0)
        guard case .agentEvent(let decoded) = try roundTrip(HostMessage.agentEvent(event)) else {
            return XCTFail("an agent event must decode as one")
        }
        XCTAssertNil(decoded.note)
        XCTAssertEqual(decoded, event)
    }

    func testAVocabularyChunkRoundTripsItsSequenceAndFinalFlag() throws {
        let payload = VocabularyPayload(targetID: "t-1",
                                        terms: ["NimletTransport", "NWParameters", "psk"],
                                        sequence: 2, isFinal: true)
        guard case .vocabulary(let decoded) = try roundTrip(HostMessage.vocabulary(payload)) else {
            return XCTFail("a vocabulary chunk must decode as one")
        }
        XCTAssertEqual(decoded, payload)
    }

    func testAPongRoundTripsTheNonceAndTheHostClock() throws {
        // The host's clock rides the pong so the panel can turn a frame's
        // capture stamp into a real latency rather than two unrelated uptimes.
        guard case .pong(let nonce, let hostTime) =
                try roundTrip(HostMessage.pong(nonce: 42, hostTime: 1_234_567)) else {
            return XCTFail("a pong must decode as a pong")
        }
        XCTAssertEqual(nonce, 42)
        XCTAssertEqual(hostTime, 1_234_567)
    }

    func testEveryAgentEventKindRoundTrips() throws {
        for kind in AgentEvent.Kind.allCases {
            let event = AgentEvent(targetID: "t-1", kind: kind, atEpochMillis: 1)
            guard case .agentEvent(let decoded) = try roundTrip(HostMessage.agentEvent(event)) else {
                return XCTFail("an agent event must decode as one")
            }
            XCTAssertEqual(decoded.kind, kind)
        }
    }

    func testEveryTargetKindRoundTrips() throws {
        for kind in NimletTarget.Kind.allCases {
            let target = NimletTarget(name: "T", kind: kind)
            guard case .targets(let decoded) = try roundTrip(HostMessage.targets([target])) else {
                return XCTFail("targets must decode as targets")
            }
            XCTAssertEqual(decoded.first?.kind, kind)
        }
    }
}
