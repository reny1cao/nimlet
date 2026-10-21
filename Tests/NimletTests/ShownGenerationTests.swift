import XCTest

/// A touch on the mirror now says which window's picture it was on, so the Mac
/// can refuse one aimed at a window it has already left — exactly, rather than
/// by guessing when the phone caught up. Both directions have to stay readable
/// by the build on the other end.
final class ShownGenerationTests: XCTestCase {

    func testAPointCarriesTheGenerationItWasAimedAt() throws {
        let line = try NimletCoder.line(ClientMessage.pointAtPanel(x: 0.25, y: 0.5, generation: 7))
        guard case .pointAtPanel(let x, let y, let generation) = try NimletCoder.decode(ClientMessage.self, from: line) else {
            return XCTFail("not a point")
        }
        XCTAssertEqual(x, 0.25)
        XCTAssertEqual(y, 0.5)
        XCTAssertEqual(generation, 7)
    }

    /// An older phone's point decodes, with no generation — and the Mac then
    /// falls back to timing, as before.
    func testAPointFromAnOlderPhoneDecodesWithoutOne() throws {
        let old = #"{"pointAtPanel":{"x":0.1,"y":0.9}}"#
        guard case .pointAtPanel(_, _, let generation) = try NimletCoder.decode(ClientMessage.self, from: Data(old.utf8)) else {
            return XCTFail("not a point")
        }
        XCTAssertNil(generation)
    }

    /// An older Mac reads `x` and `y` and nothing else, so a point with no
    /// generation must be byte-for-byte what it always was.
    func testAPointWithoutAGenerationLeavesTheKeyOut() throws {
        let text = String(decoding: try NimletCoder.line(ClientMessage.pointAtPanel(x: 1, y: 0)), as: UTF8.self)
        XCTAssertFalse(text.contains("generation"))
    }

    func testAFrameCarriesItsWindowGenerationAndAnOldOneDecodesWithout() throws {
        var frame = ViewFrame(kind: .video, title: "Notes", captureTime: 1)
        frame.generation = 3
        let decoded = try JSONDecoder().decode(ViewFrame.self, from: JSONEncoder().encode(frame))
        XCTAssertEqual(decoded.generation, 3)
        let old = #"{"kind":"video","title":"Notes","captureTime":1}"#
        XCTAssertNil(try JSONDecoder().decode(ViewFrame.self, from: Data(old.utf8)).generation)
    }
}
