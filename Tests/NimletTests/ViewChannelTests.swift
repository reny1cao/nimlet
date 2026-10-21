import XCTest

/// The panel channel's framing, and the one thing it now has to report.
///
/// The desync signal is load-bearing rather than diagnostic. Keyframes used to be
/// forced every two seconds whether anything needed one or not, so a reader that
/// lost its place repaired itself within two seconds and nobody had to notice.
/// That periodic keyframe is what stalled the link, so it is gone — which makes
/// "the reader lost its place" a thing that has to be *said*, or the picture
/// stays smeared until the ten-second safety net comes round.
final class ViewChannelTests: XCTestCase {

    private func videoFrame(keyframe: Bool = true) -> ViewFrame {
        var frame = ViewFrame(kind: .video, title: "Claude", captureTime: 42)
        frame.codec = .hevc
        frame.isKeyframe = keyframe
        frame.width = 1180
        frame.height = 2000
        return frame
    }

    // MARK: - Framing

    func testAFrameSurvivesTheRoundTripWithItsPayload() throws {
        let payload = Data([0, 0, 0, 1, 9, 10, 0xFF])
        let encoded = try ViewFrameWriter.encode(videoFrame(), payload: payload)

        var reader = ViewFrameReader()
        let frames = reader.append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.frame.kind, .video)
        XCTAssertEqual(frames.first?.frame.codec, .hevc)
        XCTAssertEqual(frames.first?.payload, payload)
        XCTAssertFalse(reader.takeDesync())
    }

    /// A keyframe is tens of kilobytes and a socket read is sixteen; the whole
    /// point of the framer is that this works.
    func testAFrameSplitAcrossReadsIsHeldUntilItIsWhole() throws {
        let encoded = try ViewFrameWriter.encode(videoFrame(), payload: Data(count: 4096))
        var reader = ViewFrameReader()
        var delivered = 0
        for chunk in stride(from: 0, to: encoded.count, by: 700) {
            let slice = encoded[chunk..<min(chunk + 700, encoded.count)]
            delivered += reader.append(Data(slice)).count
        }
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(reader.takeDesync())
    }

    func testSeveralFramesInOneReadAllComeOut() throws {
        var data = try ViewFrameWriter.encode(videoFrame(), payload: Data([1]))
        data.append(try ViewFrameWriter.encode(videoFrame(keyframe: false), payload: Data([2, 3])))

        var reader = ViewFrameReader()
        XCTAssertEqual(reader.append(data).map(\.frame.isKeyframe), [true, false])
    }

    // MARK: - Losing the thread, and saying so

    func testAnImpossibleHeaderLengthIsReportedAsADesync() {
        var reader = ViewFrameReader()
        // A header claiming more than any real frame. There is no recovering a
        // byte offset we have lost, so the buffer goes — and the caller has to
        // learn that the picture is now built on sand.
        var garbage = Data()
        garbage.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        garbage.append(Data(count: 64))

        XCTAssertTrue(reader.append(garbage).isEmpty)
        XCTAssertTrue(reader.takeDesync())
    }

    func testAnImpossiblePayloadLengthIsReportedAsADesync() throws {
        let encoded = try ViewFrameWriter.encode(videoFrame(), payload: Data([1, 2, 3]))
        // Keep the header intact and corrupt the payload length that follows it.
        let headerLength = Int(encoded[0]) << 24 | Int(encoded[1]) << 16
            | Int(encoded[2]) << 8 | Int(encoded[3])
        var broken = encoded
        for offset in 0..<4 { broken[4 + headerLength + offset] = 0xFF }

        var reader = ViewFrameReader()
        XCTAssertTrue(reader.append(broken).isEmpty)
        XCTAssertTrue(reader.takeDesync())
    }

    /// Reading it clears it: the caller asks for a keyframe once per episode, not
    /// once per read for the rest of the connection.
    func testTheDesyncIsReportedOnceAndThenForgotten() {
        var reader = ViewFrameReader()
        _ = reader.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        XCTAssertTrue(reader.takeDesync())
        XCTAssertFalse(reader.takeDesync())
    }

    func testAFreshReaderHasLostNothing() {
        var reader = ViewFrameReader()
        XCTAssertFalse(reader.takeDesync())
    }

    /// A reader that threw its buffer away has to be usable afterwards — the
    /// keyframe it asks for arrives on the same socket.
    func testItFramesAgainAfterADesync() throws {
        var reader = ViewFrameReader()
        _ = reader.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        XCTAssertTrue(reader.takeDesync())

        let encoded = try ViewFrameWriter.encode(videoFrame(), payload: Data([7]))
        XCTAssertEqual(reader.append(encoded).count, 1)
        XCTAssertFalse(reader.takeDesync())
    }
}
