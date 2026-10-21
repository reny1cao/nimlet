import XCTest
import CoreGraphics
import CoreMedia
import CoreText
import VideoToolbox

/// A still window is encoded again until it is sharp — a bounded number of
/// times, and only as fast as the link allows.
final class StillRefinementTests: XCTestCase {

    func testAStillPictureGetsAFixedNumberOfPasses() {
        var refinement = StillRefinement()
        var passes = 0
        while refinement.wantsAnother {
            _ = refinement.offered(taken: true)
            passes += 1
        }
        XCTAssertEqual(passes, StillRefinement.passes)
    }

    /// A pass the link had no room for is offered again, but a link that
    /// stays full cannot keep a refinement alive for ever.
    func testALinkWithNoRoomEndsTheRefinementRatherThanRetryingForever() {
        var refinement = StillRefinement()
        var offers = 0
        while refinement.wantsAnother {
            _ = refinement.offered(taken: false)
            offers += 1
        }
        XCTAssertEqual(offers, StillRefinement.attempts)
        XCTAssertEqual(refinement.passesTaken, 0)
    }

    func testAChangedPictureStartsAgain() {
        var refinement = StillRefinement()
        for _ in 0..<StillRefinement.passes { _ = refinement.offered(taken: true) }
        XCTAssertFalse(refinement.wantsAnother)
        refinement.pictureChanged()
        XCTAssertTrue(refinement.wantsAnother)
        XCTAssertEqual(refinement.passesTaken, 0)
    }

    /// The passes' own rate, so each may spend the time it actually has.
    func testTheEncoderIsToldThePassesOwnRate() {
        XCTAssertEqual(StillRefinement.framesPerSecond * StillRefinement.interval, 1, accuracy: 1e-9)
    }

    // MARK: - With the real encoder

    /// The claim the passes rest on, with the hardware encoder: a terminal-like
    /// picture attached at a far viewer's starting rate arrives soft, and passes
    /// over the same pixels — the encoder told their rate — sharpen it.
    func testPassesOverAStillPictureSharpenIt() throws {
        let width = 1768, height = 1104
        let source = try terminalPicture(width: width, height: height)
        let encoder = VideoEncoder()
        XCTAssertTrue(encoder.prepare(width: width, height: height, bitrate: VideoPacer.farStart, fps: 60))
        defer { encoder.invalidate() }
        let decoder = TestDecoder()
        var stamp: Int64 = 0

        func pass() throws -> (psnr: Double, bytes: Int)? {
            stamp += 1
            let done = DispatchSemaphore(value: 0)
            var result: VideoEncoder.Output?
            XCTAssertTrue(encoder.encode(source, at: CMTime(value: stamp, timescale: 4)) { output in
                result = output
                done.signal()
            })
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            guard let result else { return nil }
            let shown = try XCTUnwrap(decoder.decode(result))
            return (lumaPSNR(source, shown), result.data.count)
        }

        let first = try XCTUnwrap(try pass())
        encoder.retune(bitrate: VideoPacer.farStart, fps: StillRefinement.framesPerSecond)
        var best = first.psnr
        var bytes = 0
        for _ in 0..<StillRefinement.passes {
            Thread.sleep(forTimeInterval: StillRefinement.interval)
            if let refined = try pass() {
                best = max(best, refined.psnr)
                bytes += refined.bytes
            }
        }
        print(String(format: "still refinement at 1 Mbps: %.1f dB -> %.1f dB, %d KB over %d passes",
                     first.psnr, best, bytes / 1000, StillRefinement.passes))
        XCTAssertGreaterThan(best, first.psnr + 4, "the passes have to show")
        let budget = Double(VideoPacer.farStart) / 8 * StillRefinement.interval * Double(StillRefinement.passes)
        XCTAssertLessThan(Double(bytes), budget * 1.5, "and stay within what the link was measured to carry")
    }

    // MARK: - Helpers

    /// Lines of coloured monospaced text on a dark background, NV12 like
    /// ScreenCaptureKit hands over: the content that blurs first.
    private func terminalPicture(width: Int, height: Int) throws -> CVPixelBuffer {
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        let canvas = try XCTUnwrap(bgra)
        CVPixelBufferLockBaseAddress(canvas, [])
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(canvas), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(canvas), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 15, nil)
        let colours = [CGColor(red: 0.85, green: 0.87, blue: 0.9, alpha: 1),
                       CGColor(red: 0.55, green: 0.8, blue: 0.5, alpha: 1),
                       CGColor(red: 0.95, green: 0.75, blue: 0.4, alpha: 1)]
        let words = ["func", "guard", "return", "encoder", "keyframe", "PanelStreamer", "bitrate:", "{", "}",
                     "Tests passed", "Read", "Bash", "src/main.rs:42", "let", "self.lock.withLock"]
        var y = height - 24
        var line = 0
        while y > 0 {
            let text = (0..<(4 + (line * 7) % 15)).map { words[($0 * 5 + line * 3) % words.count] }.joined(separator: " ")
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colours[line % colours.count],
            ]
            context.textPosition = CGPoint(x: 16, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            y -= 20
            line += 1
        }
        CVPixelBufferUnlockBaseAddress(canvas, [])

        var nv12: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nv12)
        let picture = try XCTUnwrap(nv12)
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        XCTAssertEqual(VTPixelTransferSessionTransferImage(try XCTUnwrap(transfer), from: canvas, to: picture), noErr)
        return picture
    }

    private func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0)
        let sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var sum = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let d = Double(pa[row * sa + column]) - Double(pb[row * sb + column])
                sum += d * d
            }
        }
        let mse = sum / Double(width * height)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

/// What the phone does with a frame, minus the screen: parameter sets into a
/// format, length-prefixed NAL units into a sample, and a hardware decode.
private final class TestDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ output: VideoEncoder.Output) -> CVPixelBuffer? {
        if !output.parameterSets.isEmpty {
            format = makeFormat(output.parameterSets, hevc: output.codec == .hevc)
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
        }
        guard let format else { return nil }
        if session == nil {
            VTDecompressionSessionCreate(
                allocator: nil, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
        }
        guard let session else { return nil }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: output.data.count,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: output.data.count, flags: 0, blockBufferOut: &block)
        guard let block else { return nil }
        output.data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: output.data.count)
        }
        var sample: CMSampleBuffer?
        var size = output.data.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return nil }
        var image: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
            image = buffer
        }
        return image
    }

    private func makeFormat(_ sets: [Data], hevc: Bool) -> CMVideoFormatDescription? {
        let copies = sets.map { [UInt8]($0) }
        var format: CMVideoFormatDescription?
        let pointers = copies.map { copy -> UnsafePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: copy.count)
            buffer.initialize(from: copy, count: copy.count)
            return UnsafePointer(buffer)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = copies.map(\.count)
        let status = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}
