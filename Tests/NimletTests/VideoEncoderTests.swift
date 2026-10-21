import XCTest
import CoreVideo
import CoreMedia
import OSLog

// The encoder is compiled without the host's listeners in this test target.
let miceLog = Logger(subsystem: "com.renyicao.mice", category: "host")

final class VideoEncoderTests: XCTestCase {
    private func buffer(width: Int = 320, height: Int = 180) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                        &result)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 80, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testFramesCompleteAcrossRepeatedResizeAndStop() throws {
        let encoder = VideoEncoder()
        let outputs = DispatchGroup()
        let countLock = NSLock()
        var submitted = 0
        var completed = 0
        var pictures = 0
        for index in 0..<40 {
            let width = index.isMultiple(of: 2) ? 320 : 384
            XCTAssertTrue(encoder.prepare(width: width, height: 180, bitrate: 1_500_000, fps: 30))
            let pixels = try buffer(width: width)
            for frame in 0..<3 {
                outputs.enter()
                if encoder.encode(pixels, at: CMTime(value: Int64(index * 3 + frame), timescale: 30), output: { output in
                    countLock.withLock {
                        completed += 1
                        if output != nil { pictures += 1 }
                    }
                    // Delivery can change the rate or ask for a keyframe, including during a drain.
                    encoder.retune(bitrate: 1_000_000, fps: 30)
                    encoder.requestKeyframe()
                    outputs.leave()
                }) {
                    submitted += 1
                } else {
                    outputs.leave()
                }
            }
            encoder.invalidate()
        }
        XCTAssertEqual(outputs.wait(timeout: .now() + 15), .success, "Shutdown must release every submitted frame")
        XCTAssertEqual(completed, submitted)
        XCTAssertGreaterThan(pictures, 0)
    }

    func testConcurrentRetuneStopAndResizeCanResumeEncoding() throws {
        let encoder = VideoEncoder()
        let pixels = try buffer()
        let work = DispatchGroup()
        let outputs = DispatchGroup()
        let worker = DispatchQueue(label: "nimlet.encoder.stress", attributes: .concurrent)
        work.enter()
        worker.async {
            defer { work.leave() }
            for index in 0..<80 {
                _ = encoder.prepare(width: 320, height: 180, bitrate: 1_500_000, fps: 30)
                outputs.enter()
                if !encoder.encode(pixels, at: CMTime(value: Int64(index), timescale: 30), output: { _ in outputs.leave() }) {
                    outputs.leave()
                }
            }
        }
        work.enter()
        worker.async {
            defer { work.leave() }
            for index in 0..<160 {
                encoder.retune(bitrate: index.isMultiple(of: 2) ? 1_000_000 : 1_500_000, fps: 30)
                encoder.invalidate()
            }
        }
        XCTAssertEqual(work.wait(timeout: .now() + 20), .success, "Concurrent session changes must not deadlock")
        encoder.invalidate()
        XCTAssertEqual(outputs.wait(timeout: .now() + 15), .success)

        XCTAssertTrue(encoder.prepare(width: 320, height: 180, bitrate: 1_500_000, fps: 30))
        let recovered = expectation(description: "Fresh stream produces a picture")
        XCTAssertTrue(encoder.encode(pixels, at: CMTime(value: 1000, timescale: 30), output: { output in
            XCTAssertNotNil(output)
            XCTAssertTrue(output?.isKeyframe == true)
            recovered.fulfill()
        }))
        encoder.invalidate()
        wait(for: [recovered], timeout: 10)
    }
}
