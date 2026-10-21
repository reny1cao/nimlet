import XCTest

/// The listen channel: the framing, the packet arithmetic, and the cushion.
///
/// All three are worth tests for the same reason, which is that every way they
/// can be wrong sounds like a network problem. A packet length off by one is a
/// click; a cushion that chatters is a stutter; a frame decoded against the
/// wrong offsets is noise. None of those point at the code that caused them, and
/// none can be checked by listening, because the thing you are listening for is
/// the absence of a rare fault.
final class AudioChannelTests: XCTestCase {

    // MARK: - Framing

    func testAFrameSurvivesTheRoundTripWithItsPayload() throws {
        var frame = AudioFrame(kind: .audio, captureTime: 99)
        frame.codec = .aac
        frame.sampleRate = 48_000
        frame.channels = 2
        frame.framesPerPacket = 1024
        frame.packets = [3, 2]
        frame.sequence = 7
        let payload = Data([1, 2, 3, 9, 9])

        let encoded = try AudioFrameWriter.encode(frame, payload: payload)
        var reader = AudioFrameReader()
        let frames = reader.append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.frame.kind, .audio)
        XCTAssertEqual(frames.first?.frame.sampleRate, 48_000)
        XCTAssertEqual(frames.first?.frame.sequence, 7)
        XCTAssertEqual(frames.first?.payload, payload)
    }

    /// The Mac sends the format every couple of seconds, not on every frame, so
    /// most frames arrive describing nothing. That has to decode.
    func testAFrameThatDescribesNothingStillDecodes() throws {
        var frame = AudioFrame(kind: .audio, captureTime: 1)
        frame.packets = [2]
        let encoded = try AudioFrameWriter.encode(frame, payload: Data([7, 8]))
        var reader = AudioFrameReader()
        let decoded = reader.append(encoded).first

        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.frame.sampleRate)
        XCTAssertNil(decoded?.frame.codec)
    }

    /// Two frames in one read is the normal case: 23 frames a second against a
    /// socket that hands over whatever has arrived.
    func testSeveralFramesInOneReadAllComeOut() throws {
        var first = AudioFrame(kind: .audio, captureTime: 1)
        first.packets = [1]
        var second = AudioFrame(kind: .audio, captureTime: 2)
        second.packets = [2]
        var data = try AudioFrameWriter.encode(first, payload: Data([1]))
        data.append(try AudioFrameWriter.encode(second, payload: Data([2, 3])))

        var reader = AudioFrameReader()
        let frames = reader.append(data)
        XCTAssertEqual(frames.map(\.frame.captureTime), [1, 2])
    }

    func testAFrameSplitAcrossReadsIsHeldUntilItIsWhole() throws {
        var frame = AudioFrame(kind: .audio, captureTime: 5)
        frame.packets = [4]
        let encoded = try AudioFrameWriter.encode(frame, payload: Data([1, 2, 3, 4]))

        var reader = AudioFrameReader()
        XCTAssertTrue(reader.append(encoded.prefix(encoded.count - 2)).isEmpty)
        XCTAssertEqual(reader.append(encoded.suffix(2)).count, 1)
    }

    func testAStateFrameCarriesItsReasonAndNoPayload() throws {
        let encoded = try AudioFrameWriter.encode(.state("This Mac is set not to send its audio"),
                                                  payload: Data())
        var reader = AudioFrameReader()
        let decoded = reader.append(encoded).first
        XCTAssertEqual(decoded?.frame.kind, .state)
        XCTAssertEqual(decoded?.frame.reason, "This Mac is set not to send its audio")
        XCTAssertEqual(decoded?.payload.count, 0)
    }

    // MARK: - Packet arithmetic

    /// The one thing on this channel that slices a buffer using numbers off the
    /// wire. Everything below is a way of getting that wrong.
    func testPacketRangesSplitThePayloadWhereTheLengthsSay() {
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [2, 3, 1]
        let ranges = frame.packetRanges(in: Data(count: 6))
        XCTAssertEqual(ranges, [0..<2, 2..<5, 5..<6])
    }

    func testLengthsThatOverrunThePayloadAreRefusedRatherThanTruncated() {
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [4, 4]
        XCTAssertNil(frame.packetRanges(in: Data(count: 6)),
                     "a short payload is a frame we do not understand, not most of one")
    }

    func testLengthsThatLeaveBytesOverAreRefused() {
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [2]
        XCTAssertNil(frame.packetRanges(in: Data(count: 6)))
    }

    func testAZeroLengthPacketIsRefused() {
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [0, 2]
        XCTAssertNil(frame.packetRanges(in: Data(count: 2)))
    }

    func testANegativeLengthIsRefused() {
        var frame = AudioFrame(kind: .audio, captureTime: 0)
        frame.packets = [-1, 3]
        XCTAssertNil(frame.packetRanges(in: Data(count: 2)))
    }

    func testAFrameWithNoPacketsHasNoRanges() {
        XCTAssertNil(AudioFrame(kind: .audio, captureTime: 0).packetRanges(in: Data([1, 2])))
    }

    // MARK: - The hello

    /// `paused` is absent rather than false on the wire, and an older phone does
    /// not send it at all. Both have to read as "not paused".
    func testAHelloWithoutPausedIsNotPaused() throws {
        let line = try NimletCoder.line(ClientMessage.listenHello(
            ListenHelloPayload(deviceName: "iPhone", deviceID: "abc")))
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("paused"),
                       "the common case costs nothing on the wire")

        guard case .listenHello(let decoded) = try NimletCoder.decode(
            ClientMessage.self, from: line) else { return XCTFail("not a listenHello") }
        XCTAssertFalse(decoded.isPaused)
        XCTAssertEqual(decoded.protocolVersion, NimletProtocol.version)
    }

    func testAPausedHelloSurvivesTheRoundTrip() throws {
        let line = try NimletCoder.line(ClientMessage.listenHello(
            ListenHelloPayload(deviceName: "iPhone", deviceID: "abc", paused: true)))
        guard case .listenHello(let decoded) = try NimletCoder.decode(
            ClientMessage.self, from: line) else { return XCTFail("not a listenHello") }
        XCTAssertTrue(decoded.isPaused)
    }

    // MARK: - The cushion

    func testNothingPlaysUntilThereIsAFullCushion() {
        let window = JitterWindow()
        XCTAssertEqual(window.verdict(depth: window.target - 0.001, isPlaying: false), .fill)
        XCTAssertEqual(window.verdict(depth: window.target, isPlaying: false), .play)
    }

    /// The hysteresis, and without it the buffer chatters: a stream that starts
    /// on one packet underruns on the next render cycle, forever.
    func testOncePlayingASingleSampleIsEnoughToCarryOn() {
        let window = JitterWindow()
        XCTAssertEqual(window.verdict(depth: 0.001, isPlaying: true), .play)
        XCTAssertEqual(window.verdict(depth: 0, isPlaying: true), .fill)
    }

    func testTooFarAheadSkipsBackToTheTarget() {
        let window = JitterWindow()
        guard case .skip(let seconds) = window.verdict(depth: window.ceiling + 0.2, isPlaying: true) else {
            return XCTFail("a buffer past the ceiling is a delay, not a cushion")
        }
        XCTAssertEqual(window.ceiling + 0.2 - seconds, window.target, accuracy: 0.0001,
                       "the skip leaves exactly the target behind")
    }

    func testABurstInsideTheCeilingIsNotPunished() {
        let window = JitterWindow()
        XCTAssertEqual(window.verdict(depth: window.ceiling - 0.001, isPlaying: true), .play,
                       "arriving in bursts is what a good link on a busy network looks like")
    }

    func testEachDropoutAsksForABiggerCushion() {
        var window = JitterWindow()
        let start = window.target
        window.noteUnderrun()
        XCTAssertGreaterThan(window.target, start)
        for _ in 0..<200 { window.noteUnderrun() }
        XCTAssertEqual(window.target, JitterWindow.maximum, accuracy: 0.0001,
                       "it grows to a ceiling, not without bound")
    }

    func testCleanPlaybackTrimsTheCushionBackOneStepAtATime() {
        var window = JitterWindow()
        window.noteUnderrun()
        window.noteUnderrun()
        let grown = window.target

        // Not yet: a link that has been quiet for ten seconds has not earned it.
        window.noteClean(seconds: JitterWindow.calm - 1)
        XCTAssertEqual(window.target, grown, accuracy: 0.0001)

        window.noteClean(seconds: 1)
        XCTAssertEqual(window.target, grown - JitterWindow.decay, accuracy: 0.0001)
    }

    func testTheCushionNeverShrinksPastTheMinimum() {
        var window = JitterWindow()
        for _ in 0..<50 { window.noteClean(seconds: JitterWindow.calm) }
        XCTAssertEqual(window.target, JitterWindow.minimum, accuracy: 0.0001)
    }

    /// Where the cushion starts matters: it is the delay every listener pays
    /// before anything has gone wrong, and it has to be several packets so that
    /// one late frame is absorbed rather than heard.
    func testTheCushionStartsAtSeveralPacketsAndStaysInsideItsBounds() {
        XCTAssertGreaterThanOrEqual(JitterWindow.minimum, AudioChannel.packetSeconds * 3)
        XCTAssertLessThan(JitterWindow.minimum, JitterWindow.maximum)
        XCTAssertEqual(JitterWindow(target: 10).target, JitterWindow.maximum, accuracy: 0.0001)
        XCTAssertEqual(JitterWindow(target: 0).target, JitterWindow.minimum, accuracy: 0.0001)
    }

    func testAPacketIsTheDurationBothEndsThinkItIs() {
        XCTAssertEqual(AudioChannel.packetSeconds, 1024.0 / 48_000.0, accuracy: 1e-9)
        XCTAssertEqual(AudioChannel.framesPerPacket, 1024)
        XCTAssertEqual(AudioChannel.sampleRate, 48_000)
    }
}
