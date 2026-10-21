import XCTest

final class WindowAutoFitTests: XCTestCase {
    func testSwitchingWindowsFitsEachSelectionIncludingReturningToOne() {
        var fit = WindowAutoFit()
        let wide = CGSize(width: 1200, height: 600)
        XCTAssertTrue(fit.shouldFit(windowID: 10, size: wide, aspect: 1.3))
        XCTAssertFalse(fit.shouldFit(windowID: 10, size: wide, aspect: 1.3),
                       "A constrained app must not be resized on every watchdog tick")
        XCTAssertTrue(fit.shouldFit(windowID: 20, size: wide, aspect: 1.3))
        XCTAssertTrue(fit.shouldFit(windowID: 10, size: wide, aspect: 1.3))
    }

    func testOnlyAChangedLayoutOrNewSessionRetriesTheSameWindow() {
        var fit = WindowAutoFit()
        let wide = CGSize(width: 1200, height: 600)
        XCTAssertTrue(fit.shouldFit(windowID: 10, size: wide, aspect: 1.1231))
        XCTAssertFalse(fit.shouldFit(windowID: 10, size: wide, aspect: 1.1232))
        XCTAssertTrue(fit.shouldFit(windowID: 10, size: wide, aspect: 0.6))
        fit.reset()
        XCTAssertTrue(fit.shouldFit(windowID: 10, size: wide, aspect: 0.6))
    }

    func testMatchingWindowsAndSmallRoundingDifferencesStayPut() {
        var fit = WindowAutoFit()
        XCTAssertFalse(fit.shouldFit(windowID: 1, size: CGSize(width: 780, height: 600), aspect: 1.3))
        XCTAssertFalse(fit.shouldFit(windowID: 2, size: CGSize(width: 787, height: 600), aspect: 1.3))
        XCTAssertTrue(fit.shouldFit(windowID: 3, size: CGSize(width: 850, height: 600), aspect: 1.3))
    }

    func testInvalidGeometryCannotResizeOrConsumeTheNextValidAttempt() {
        var fit = WindowAutoFit()
        for value in [nil, .nan, .infinity, 0, -1, 0.1, 10, 100] as [Double?] {
            XCTAssertFalse(fit.shouldFit(windowID: 1, size: CGSize(width: 1200, height: 600), aspect: value))
        }
        XCTAssertFalse(fit.shouldFit(windowID: 1, size: .zero, aspect: 1.3))
        XCTAssertTrue(fit.shouldFit(windowID: 1, size: CGSize(width: 1200, height: 600), aspect: 1.3))
    }

    func testWindowFitTravelsSeparatelyFromEncodeSizeAndCrop() throws {
        let hello = ViewHelloPayload(deviceName: "Phone", deviceID: "phone-key",
                                     maxWidth: 2048, maxHeight: 1024,
                                     crop: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4),
                                     fitAspect: 1.35)
        let data = try NimletCoder.encode(ClientMessage.viewHello(hello))
        guard case .viewHello(let received) = try NimletCoder.decode(ClientMessage.self, from: data) else {
            return XCTFail("Expected viewer hello")
        }
        XCTAssertEqual(received.fitAspect, 1.35)
        XCTAssertEqual(received.maxWidth, 2048)
        XCTAssertEqual(received.maxHeight, 1024)
        XCTAssertEqual(received.cropRect, hello.cropRect)
    }

    func testOlderViewersKeepTheirWindowsExistingSize() throws {
        let json = Data(#"{"protocolVersion":1,"deviceName":"Old phone","deviceID":"p","maxWidth":1000,"maxHeight":600}"#.utf8)
        let hello = try NimletCoder.decode(ViewHelloPayload.self, from: json)
        XCTAssertNil(hello.fitAspect)
    }
}
