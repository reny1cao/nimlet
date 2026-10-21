import XCTest

/// `LineFramer` sits underneath every message either end receives, so a bug
/// here does not fail loudly — it makes individual messages disappear.
final class LineFramerTests: XCTestCase {

    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testACompleteLineArrivesWithoutItsTerminatingNewline() {
        var framer = LineFramer()
        XCTAssertEqual(strings(framer.append(bytes("hello\n"))), ["hello"])
    }

    func testSeveralMessagesInOnePacketAllComeOutInArrivalOrder() {
        var framer = LineFramer()
        let lines = framer.append(bytes("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n"))
        XCTAssertEqual(strings(lines), ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
    }

    func testAMessageSplitAcrossPacketsIsWithheldUntilItsNewlineArrives() {
        var framer = LineFramer()
        XCTAssertTrue(framer.append(bytes("{\"text\":\"sum")).isEmpty)
        XCTAssertTrue(framer.append(bytes("marise the di")).isEmpty)
        XCTAssertEqual(strings(framer.append(bytes("ff\"}\n"))),
                       ["{\"text\":\"summarise the diff\"}"])
    }

    func testAMessageSplitInTheMiddleOfItsNewlineStillFramesOnce() {
        var framer = LineFramer()
        XCTAssertTrue(framer.append(bytes("ping")).isEmpty)
        XCTAssertEqual(strings(framer.append(bytes("\n"))), ["ping"])
    }

    func testATrailingFragmentIsHeldBackAndCompletedByTheNextPacket() {
        var framer = LineFramer()
        XCTAssertEqual(strings(framer.append(bytes("first\nsec"))), ["first"])
        XCTAssertEqual(strings(framer.append(bytes("ond\n"))), ["second"])
    }

    func testEmptyLinesAreSkippedRatherThanDeliveredAsEmptyPayloads() {
        var framer = LineFramer()
        XCTAssertEqual(strings(framer.append(bytes("\n\n"))), [])
        XCTAssertEqual(strings(framer.append(bytes("a\n\n\nb\n"))), ["a", "b"])
    }

    func testMultiByteCharactersSurviveBeingSplitAcrossPackets() {
        var framer = LineFramer()
        let payload = Array("héllo → done".utf8)
        XCTAssertTrue(framer.append(Data(payload[0..<4])).isEmpty)
        let lines = framer.append(Data(payload[4...]) + bytes("\n"))
        XCTAssertEqual(strings(lines), ["héllo → done"])
    }

    func testAFreshFramerHasDroppedNothing() {
        let framer = LineFramer()
        XCTAssertEqual(framer.droppedLines, 0)
    }

    func testALineThatPassesTheCapWithNoNewlineInSightIsDroppedAndCounted() {
        var framer = LineFramer(maxLineBytes: 32)
        XCTAssertTrue(framer.append(Data(repeating: 0x41, count: 33)).isEmpty)
        XCTAssertEqual(framer.droppedLines, 1)
    }

    func testTheFramerResynchronisesToTheNextNewlineAfterAnOverlongLine() {
        var framer = LineFramer(maxLineBytes: 32)
        _ = framer.append(Data(repeating: 0x41, count: 33))
        let lines = framer.append(bytes("AAAA\nback-in-sync\n"))
        XCTAssertEqual(strings(lines), ["back-in-sync"])
        XCTAssertEqual(framer.droppedLines, 1)
    }

    func testAnIntactMessageInTheSamePacketAsTheEndOfAnOverlongLineStillComesThrough() {
        var framer = LineFramer(maxLineBytes: 32)
        _ = framer.append(Data(repeating: 0x41, count: 33))
        // Both messages share the packet that also carries the tail of the
        // overlong line. Discarding the whole buffer used to take them with it.
        let lines = framer.append(bytes("tail-of-the-overlong-line\nkept-one\nkept-two\n"))
        XCTAssertEqual(strings(lines), ["kept-one", "kept-two"])
    }

    func testBytesArrivingWhileResynchronisingDoNotCountAsAnotherDroppedLine() {
        var framer = LineFramer(maxLineBytes: 32)
        _ = framer.append(Data(repeating: 0x41, count: 33))
        XCTAssertTrue(framer.append(Data(repeating: 0x41, count: 4096)).isEmpty)
        XCTAssertEqual(framer.droppedLines, 1)
    }

    func testTwoOverlongLinesInARowAreBothCounted() {
        var framer = LineFramer(maxLineBytes: 32)
        _ = framer.append(Data(repeating: 0x41, count: 33))
        _ = framer.append(bytes("tail\n"))
        _ = framer.append(Data(repeating: 0x42, count: 33))
        XCTAssertEqual(framer.droppedLines, 2)
        XCTAssertEqual(strings(framer.append(bytes("tail\nalive\n"))), ["alive"])
    }

    func testTheDefaultCapIsOneMebibyteAndDropsAPayloadThatExceedsIt() {
        var framer = LineFramer()
        let oneMebibyte = 1 << 20
        XCTAssertTrue(framer.append(Data(repeating: 0x41, count: oneMebibyte)).isEmpty)
        XCTAssertEqual(framer.droppedLines, 0, "a line exactly at the cap is still in play")

        XCTAssertTrue(framer.append(Data(repeating: 0x41, count: 1)).isEmpty)
        XCTAssertEqual(framer.droppedLines, 1)
        XCTAssertEqual(strings(framer.append(bytes("tail\n{\"ok\":true}\n"))), ["{\"ok\":true}"])
    }

    func testALineJustUnderTheCapIsDeliveredRatherThanDropped() {
        var framer = LineFramer(maxLineBytes: 64)
        let line = String(repeating: "A", count: 64)
        XCTAssertEqual(strings(framer.append(bytes(line + "\n"))), [line])
        XCTAssertEqual(framer.droppedLines, 0)
    }
}
