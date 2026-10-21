import XCTest

final class MoveAccumulatorTests: XCTestCase {

    /// A burst read after a retransmission: the displacement is exactly the
    /// sum, delivered as one move.
    func testABurstOfMovesLandsWhereTheyAllWould() {
        var moves = MoveAccumulator()
        for _ in 0..<60 { moves.add(dx: 1.25, dy: -0.5) }
        let taken = moves.take()
        XCTAssertEqual(taken?.dx ?? 0, 75, accuracy: 1e-9)
        XCTAssertEqual(taken?.dy ?? 0, -30, accuracy: 1e-9)
        XCTAssertEqual(taken?.count, 60)
        XCTAssertNil(moves.take(), "taking empties it")
    }

    /// What the host does with a batch: sum runs of moves, flush before
    /// anything else. A click lands after the moves that preceded it and
    /// before the ones that follow, and two clicks keep their order.
    func testOnlyConsecutiveMovesAreSummedAndEverythingElseKeepsItsPlace() {
        let batch: [ClientMessage] = [
            .move(dx: 1, dy: 0), .move(dx: 2, dy: 0),
            .click(button: .left, phase: .down, clickCount: 1),
            .move(dx: 0, dy: 3), .move(dx: 0, dy: 4),
            .click(button: .left, phase: .up, clickCount: 1),
            .scroll(dx: 0, dy: 5),
            .move(dx: 7, dy: 7),
        ]
        var injected: [String] = []
        var moves = MoveAccumulator()
        func flush() {
            if let move = moves.take() { injected.append("move \(Int(move.dx)),\(Int(move.dy))") }
        }
        for message in batch {
            if case .move(let dx, let dy) = message { moves.add(dx: dx, dy: dy); continue }
            flush()
            switch message {
            case .click(_, let phase, _): injected.append("click \(phase)")
            case .scroll: injected.append("scroll")
            default: break
            }
        }
        flush()
        XCTAssertEqual(injected, ["move 3,0", "click down", "move 0,7", "click up", "scroll", "move 7,7"])
    }
}
