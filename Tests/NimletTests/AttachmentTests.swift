import XCTest

/// Attachments ride a connection of their own, framed by length rather than by
/// newline — because an image payload is full of newlines, and the control
/// channel's framer would cut one into pieces that each fail to decode and then
/// vanish without a word. These tests are that claim, checked.
final class AttachmentTests: XCTestCase {

    private func frame(_ index: Int, bytes: Int, format: AttachmentFrame.Format = .png) -> AttachmentFrame {
        AttachmentFrame(index: index, format: format, byteCount: bytes, width: 1200, height: 800)
    }

    /// Deliberately full of newlines and nulls: the bytes a PNG actually
    /// contains, and the reason none of this can be line-framed.
    private func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 % 11 == 0) ? 0x0A : ($0 % 7 == 0 ? 0x00 : 0x41)) })
    }

    func testAnAttachmentComesBackExactlyAsItWentIn() throws {
        let body = payload(4096)
        let wire = try AttachmentFrameWriter.encode(frame(0, bytes: body.count), payload: body)
        var reader = AttachmentFrameReader()
        let read = reader.append(wire)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.payload, body)
        XCTAssertEqual(read.first?.frame.index, 0)
        XCTAssertEqual(read.first?.frame.byteCount, body.count)
    }

    func testEveryNewlineInThePayloadSurvives() throws {
        let body = payload(2048)
        XCTAssertTrue(body.contains(0x0A), "the fixture has to contain the byte this is about")
        let wire = try AttachmentFrameWriter.encode(frame(0, bytes: body.count), payload: body)
        var reader = AttachmentFrameReader()
        XCTAssertEqual(reader.append(wire).first?.payload.count, body.count)
    }

    func testABatchArrivingInOnePacketComesOutInOrder() throws {
        var wire = Data()
        for index in 0..<3 {
            let body = payload(300 + index)
            wire.append(try AttachmentFrameWriter.encode(frame(index, bytes: body.count), payload: body))
        }
        var reader = AttachmentFrameReader()
        let read = reader.append(wire)
        XCTAssertEqual(read.map(\.frame.index), [0, 1, 2])
        XCTAssertEqual(read.map(\.payload.count), [300, 301, 302])
    }

    /// A 2 MB photograph does not arrive in one read, and half of one must not
    /// be delivered as though it were whole: the Mac writes what it is handed.
    func testAnAttachmentSplitAcrossPacketsIsWithheldUntilAllOfItArrives() throws {
        let body = payload(5000)
        let wire = try AttachmentFrameWriter.encode(frame(0, bytes: body.count), payload: body)
        var reader = AttachmentFrameReader()
        var offset = 0
        while offset < wire.count - 1 {
            let end = min(offset + 900, wire.count - 1)
            XCTAssertTrue(reader.append(wire.subdata(in: offset..<end)).isEmpty,
                          "a partial attachment was delivered as a whole one")
            offset = end
        }
        let finished = reader.append(wire.subdata(in: offset..<wire.count))
        XCTAssertEqual(finished.first?.payload, body)
    }

    /// A length nobody could have sent means the stream is desynced, and a byte
    /// offset that has been lost cannot be found again by reading further.
    func testAnImpossibleLengthDropsTheStreamRatherThanEmittingGarbage() throws {
        let body = payload(64)
        var wire = try AttachmentFrameWriter.encode(frame(0, bytes: body.count), payload: body)
        // Overwrite the payload length with one past the ceiling this reader was
        // built with. The header is the first four bytes plus its own JSON.
        let headerLength = Int(wire[0]) << 24 | Int(wire[1]) << 16 | Int(wire[2]) << 8 | Int(wire[3])
        let lengthOffset = 4 + headerLength
        for (index, byte) in [0x00, 0x01, 0x00, 0x00].enumerated() {
            wire[lengthOffset + index] = UInt8(byte)
        }
        var reader = AttachmentFrameReader(maxFrameBytes: 4096)
        XCTAssertTrue(reader.append(wire).isEmpty)
    }

    // MARK: - The manifest

    func testTheManifestCarriesTheCaptionSubmitAndFollowKeyWithTheBatch() throws {
        let manifest = AttachmentManifest(deviceName: "iPhone",
                                          deviceID: "device-1",
                                          targetIDs: ["a", "b"],
                                          text: "why is this cut off",
                                          submit: true,
                                          count: 2,
                                          followChord: KeyChord("escape"))
        let line = try NimletCoder.line(ClientMessage.uploadHello(manifest))
        // The line terminator is the framing, not the message.
        let decoded = try NimletCoder.decode(ClientMessage.self, from: line.dropLast())
        guard case .uploadHello(let read) = decoded else { return XCTFail("not an uploadHello") }
        XCTAssertEqual(read, manifest)
        XCTAssertEqual(read.followChord?.key, "escape")
    }

    /// `TargetStore` reseeds from scratch when its JSON fails to decode; a
    /// manifest has no such blast radius, but it has the same failure shape — an
    /// upload refused as "unreadable" tells nobody which field was at fault.
    func testAManifestMissingEverythingOptionalStillDecodes() throws {
        let json = Data(#"{"deviceID":"device-1","targetIDs":["a"],"count":1}"#.utf8)
        let manifest = try NimletCoder.decode(AttachmentManifest.self, from: json)
        XCTAssertEqual(manifest.count, 1)
        XCTAssertEqual(manifest.targetIDs, ["a"])
        XCTAssertEqual(manifest.text, "")
        XCTAssertNil(manifest.submit)
        XCTAssertNil(manifest.followChord)
        XCTAssertEqual(manifest.deviceName, "iPhone")
    }

    /// The upload socket is newline-framed for exactly one line and
    /// length-prefixed for everything after it, so the host has to be able to
    /// take back whatever the line framer was still holding.
    func testDrainHandsBackTheUnconsumedTailAndForgetsIt() {
        var framer = LineFramer()
        let lines = framer.append(Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data([0x00, 0x01, 0x0A, 0x02]))
        XCTAssertEqual(lines.count, 2, "the binary tail's newline splits it, which is why drain exists")
        let drained = framer.drain()
        XCTAssertEqual(drained, Data([0x02]))
        XCTAssertTrue(framer.drain().isEmpty)
    }
}

/// A screenshot of the Mac comes back on a connection of its own, and the phone
/// has to tell a picture from a refusal before it can read either.
final class StillTests: XCTestCase {

    private func png(_ count: Int) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47]) + Data((0..<count).map { UInt8($0 % 251) })
    }

    func testAStillComesBackWithItsTitleAndItsBytes() throws {
        let body = png(9000)
        let wire = try StillFrameWriter.encode(
            StillFrame(title: "Claude", width: 2576, height: 1449, byteCount: body.count),
            payload: body)
        var reader = StillFrameReader()
        let read = reader.append(wire)
        XCTAssertEqual(read.first?.frame.title, "Claude")
        XCTAssertEqual(read.first?.frame.width, 2576)
        XCTAssertEqual(read.first?.payload, body)
    }

    /// The phone decides which shape arrived from the first byte: a frame starts
    /// with the high byte of its header's length, and a header is never 16 MB, so
    /// that byte is zero. A refusal is JSON and starts with `{`. If that ever
    /// stops being true, a refusal is read as a frame and the user is told
    /// nothing at all.
    func testAStillFrameStartsWithZeroAndARefusalDoesNot() throws {
        let wire = try StillFrameWriter.encode(
            StillFrame(title: "Screen", width: 100, height: 100, byteCount: 4),
            payload: png(0))
        XCTAssertEqual(wire.first, 0x00)

        let refusal = try NimletCoder.line(HostMessage.error("Grant Nimlet Screen Recording first"))
        XCTAssertEqual(refusal.first, UInt8(ascii: "{"))
    }

    func testARequestMissingEverythingOptionalStillDecodes() throws {
        let json = Data(#"{"deviceID":"device-1","targetID":"t1"}"#.utf8)
        let request = try NimletCoder.decode(StillRequest.self, from: json)
        XCTAssertEqual(request.targetID, "t1")
        XCTAssertEqual(request.maxLongEdge, StillChannel.defaultLongEdge)
    }

    /// The ceiling is the resolution Claude reads an image at, which is why the
    /// Mac scales once at capture instead of sending a 6K window down the wire.
    func testTheDefaultLongEdgeMatchesWhatAttachmentsAreResizedTo() {
        XCTAssertEqual(StillChannel.defaultLongEdge, 2576)
    }
}
