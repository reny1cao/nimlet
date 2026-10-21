import XCTest
import CryptoKit

final class DirectPathTests: XCTestCase {

    private let secret = Data(repeating: 7, count: 32)

    func testPacketsRoundTripAndAStrangerCannotMakeOne() {
        let key = SymmetricKey(data: secret)
        let packet = DirectPacket.encode(.ping, seq: 42, stamp: 123_456_789, key: key)
        XCTAssertEqual(packet.count, DirectPacket.size)
        let decoded = DirectPacket.decode(packet, key: key)
        XCTAssertEqual(decoded?.kind, .ping)
        XCTAssertEqual(decoded?.seq, 42)
        XCTAssertEqual(decoded?.stamp, 123_456_789)
        // Another session's key, or one flipped bit, is nothing.
        XCTAssertNil(DirectPacket.decode(packet, key: SymmetricKey(data: Data(repeating: 8, count: 32))))
        var tampered = packet
        tampered[6] ^= 1
        XCTAssertNil(DirectPacket.decode(tampered, key: key))
        XCTAssertNil(DirectPacket.decode(packet.prefix(24), key: key))
    }

    /// RustDesk's schedule: at once, then 20 ms growing by half to 200 ms apart.
    func testPunchProbesStartDenseAndSettleAtFivePerSecond() {
        let delays = DirectPunchSchedule.delays(limit: 3)
        XCTAssertEqual(delays.first, 0)
        XCTAssertEqual(delays[1], 0.02, accuracy: 1e-9)
        XCTAssertEqual(delays[2], 0.05, accuracy: 1e-9)
        let gaps = zip(delays, delays.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, 0.2 + 1e-9)
        XCTAssertLessThanOrEqual(delays.last ?? 0, 3)
        XCTAssertGreaterThan(delays.count, 15)
    }

    func testOnlyGlobalUnicastCounts() {
        XCTAssertTrue(DirectProbe.isGlobal("2001:db8:7f:951:22:dd9d:9b98:d6e2"))
        XCTAssertFalse(DirectProbe.isGlobal("fe80::1"))
        XCTAssertFalse(DirectProbe.isGlobal("fd7a:115c:a1e0::1"), "a Tailscale address is not the internet")
        XCTAssertFalse(DirectProbe.isGlobal("::1"))
    }

    /// Two ends on loopback: both punch, the pinger measures, nothing is lost.
    func testTwoEndsPunchAndMeasureOverLoopback() throws {
        let phone = try XCTUnwrap(DirectProbe(secret: secret, address: "::1"))
        let mac = try XCTUnwrap(DirectProbe(secret: secret, address: "::1"))
        let measured = expectation(description: "phone report")
        let answered = expectation(description: "mac report")
        var phoneReport: DirectProbeReport?
        var macReport: DirectProbeReport?
        mac.start(peer: phone.local, role: .echo, measureFor: 1, punchLimit: 1) { macReport = $0; answered.fulfill() }
        phone.start(peer: mac.local, role: .pinger, measureFor: 1, punchLimit: 1) { phoneReport = $0; measured.fulfill() }
        wait(for: [measured, answered], timeout: 10)
        let report = try XCTUnwrap(phoneReport)
        XCTAssertTrue(report.punched, report.summary)
        XCTAssertEqual(report.sent, 20)
        XCTAssertEqual(report.received, 20, report.summary)
        XCTAssertLessThan(report.rttP95 ?? 999, 50)
        XCTAssertEqual(macReport?.punched, true)
        print(report.summary)
    }

    /// The other end never answers: a clear "not reachable", not a hang.
    func testAnEndThatNeverAnswersIsReportedNotReachable() throws {
        let phone = try XCTUnwrap(DirectProbe(secret: secret, address: "::1"))
        let silent = try XCTUnwrap(DirectProbe(secret: Data(repeating: 9, count: 32), address: "::1"))
        let done = expectation(description: "report")
        var report: DirectProbeReport?
        phone.start(peer: silent.local, role: .pinger, measureFor: 1, punchLimit: 0.5) { report = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(report?.punched, false)
        XCTAssertTrue(report?.summary.hasPrefix("not reachable") ?? false)
        silent.cancel()
    }
}
