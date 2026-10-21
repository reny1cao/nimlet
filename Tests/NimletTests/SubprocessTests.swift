import Foundation
import XCTest

final class SubprocessTests: XCTestCase {
    private func descriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    func testRepeatedPaneStyleCommandsReleasePipesBeforeAutoreleasePoolDrains() {
        autoreleasepool {
            let before = descriptorCount()
            for _ in 0..<100 {
                XCTAssertTrue(Subprocess.run(URL(fileURLWithPath: "/usr/bin/true"), []).ok)
            }
            XCTAssertLessThanOrEqual(descriptorCount(), before + 2, "Repeated scans must not accumulate open pipes")
        }
    }

    func testLargeInputAndOutputCannotDeadlockAndPreserveContent() {
        let text = String(repeating: "Nimlet QA\n", count: 20000)
        let result = Subprocess.run(URL(fileURLWithPath: "/bin/cat"), [], input: Data(text.utf8))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testTimeoutAndLaunchFailureReleasePipes() {
        let before = descriptorCount()
        XCTAssertFalse(Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.1).ok)
        XCTAssertFalse(Subprocess.run(URL(fileURLWithPath: "/not-a-nimlet-executable"), []).ok)
        XCTAssertLessThanOrEqual(descriptorCount(), before + 2)
    }
}
