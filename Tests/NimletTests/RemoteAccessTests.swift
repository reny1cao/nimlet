import XCTest
import Foundation

/// The byte layouts of the two protocols a router is asked for a way in with.
///
/// These are worth testing far more than most code here, because the failure mode
/// is a router that says nothing. A field in the wrong place, a length off by
/// four, a big-endian integer written little-endian: every one of those produces
/// silence that looks exactly like a router which does not speak the protocol,
/// and there is no way to tell them apart from the outside.
final class PortMapWireTests: XCTestCase {

    // MARK: - NAT-PMP

    func testANATPMPMapRequestIsTwelveBytesInTheOrderTheRFCGives() {
        let data = PortMapWire.NATPMP.mapRequest(internalPort: 61423,
                                                suggestedExternalPort: 61423,
                                                lifetime: 7200)
        XCTAssertEqual([UInt8](data), [0, 2, 0, 0, 0xEF, 0xEF, 0xEF, 0xEF, 0, 0, 0x1C, 0x20])
    }

    func testDeletingAMappingIsTheSameRequestWithNoLifetime() {
        let data = PortMapWire.NATPMP.mapRequest(internalPort: 61423,
                                                suggestedExternalPort: 0,
                                                lifetime: 0)
        XCTAssertEqual([UInt8](data).suffix(4), [0, 0, 0, 0])
    }

    func testANATPMPMapResponseIsReadBackField_forField() {
        var reply = Data([0, 130, 0, 0])            // version, op 128+2, result 0
        reply.appendBigEndian(UInt32(3_600_000))    // epoch
        reply.appendBigEndian(UInt16(61423))        // internal port
        reply.appendBigEndian(UInt16(54321))        // external port
        reply.appendBigEndian(UInt32(7200))         // lifetime
        let parsed = PortMapWire.NATPMP.parseMapResponse(reply)
        XCTAssertEqual(parsed?.result, 0)
        XCTAssertEqual(parsed?.epoch, 3_600_000)
        XCTAssertEqual(parsed?.internalPort, 61423)
        XCTAssertEqual(parsed?.externalPort, 54321,
                       "the router's answer decides the port, not what was asked for")
        XCTAssertEqual(parsed?.lifetime, 7200)
    }

    /// A gateway that speaks both answers the wrong request with the wrong
    /// opcode. Parsing that as a mapping would publish a port nobody forwarded.
    func testAResponseToADifferentOpcodeIsNotAMapping() {
        let externalAddress = Data([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 9])
        XCTAssertNil(PortMapWire.NATPMP.parseMapResponse(externalAddress))
    }

    func testATruncatedNATPMPResponseIsRefusedRatherThanRead() {
        XCTAssertNil(PortMapWire.NATPMP.parseMapResponse(Data([0, 130, 0, 0])))
        XCTAssertNil(PortMapWire.NATPMP.parseMapResponse(Data()))
    }

    func testTheExternalAddressRequestIsTwoBytes() {
        XCTAssertEqual([UInt8](PortMapWire.NATPMP.externalAddressRequest()), [0, 0])
    }

    func testTheExternalAddressComesBackAsAnAddress() {
        let reply = Data([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 9])
        let parsed = PortMapWire.NATPMP.parseExternalAddressResponse(reply)
        XCTAssertEqual(parsed?.address, "203.0.113.9")
        XCTAssertEqual(parsed?.result, 0)
    }

    func testEveryNATPMPResultCodeSaysSomethingAUserCanAct_on() {
        for code in 0...5 {
            let result = PortMapWire.NATPMP.Result(rawValue: UInt16(code))
            XCTAssertNotNil(result, "result \(code) is in the RFC and should be named")
            XCTAssertFalse(result!.message.isEmpty)
        }
    }

    // MARK: - PCP

    func testAPCPMapRequestIsSixtyBytesWithTheHeaderTheRFCGives() {
        let client = PortMapWire.mappedIPv6(fromIPv4: "192.168.1.20")!
        let nonce = Data(repeating: 0xAB, count: 12)
        let data = PortMapWire.PCP.mapRequest(clientAddress: client,
                                              nonce: nonce,
                                              internalPort: 61423,
                                              suggestedExternalPort: 61423,
                                              suggestedExternalAddress: Data(repeating: 0, count: 16),
                                              lifetime: 7200)
        XCTAssertEqual(data?.count, 60)
        let bytes = [UInt8](data!)
        XCTAssertEqual(bytes[0], 2, "version 2")
        XCTAssertEqual(bytes[1], 1, "MAP, request direction")
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0x1C, 0x20], "lifetime, big-endian")
        XCTAssertEqual(Array(bytes[8..<24]), [UInt8](client), "the client's own address")
        XCTAssertEqual(Array(bytes[24..<36]), [UInt8](nonce))
        XCTAssertEqual(bytes[36], 6, "TCP")
        XCTAssertEqual(Array(bytes[40..<44]), [0xEF, 0xEF, 0xEF, 0xEF], "both ports")
    }

    func testAPCPRequestWithAWrongSizedFieldIsRefusedRatherThanSentMalformed() {
        XCTAssertNil(PortMapWire.PCP.mapRequest(clientAddress: Data(repeating: 0, count: 4),
                                                nonce: Data(repeating: 0, count: 12),
                                                internalPort: 1,
                                                suggestedExternalPort: 1,
                                                suggestedExternalAddress: Data(repeating: 0, count: 16),
                                                lifetime: 1))
        XCTAssertNil(PortMapWire.PCP.mapRequest(clientAddress: Data(repeating: 0, count: 16),
                                                nonce: Data(repeating: 0, count: 8),
                                                internalPort: 1,
                                                suggestedExternalPort: 1,
                                                suggestedExternalAddress: Data(repeating: 0, count: 16),
                                                lifetime: 1))
    }

    func testAPCPMapResponseIsReadBackFieldForField() {
        let nonce = Data(repeating: 0x5A, count: 12)
        let external = PortMapWire.mappedIPv6(fromIPv4: "203.0.113.9")!
        var reply = Data([2, 1 | 0x80, 0, 0])   // version, MAP + response bit, reserved, result 0
        reply.appendBigEndian(UInt32(7200))     // lifetime
        reply.appendBigEndian(UInt32(99))       // epoch
        reply.append(Data(repeating: 0, count: 12))
        reply.append(nonce)
        reply.append(6)
        reply.append(contentsOf: [0, 0, 0])
        reply.appendBigEndian(UInt16(61423))
        reply.appendBigEndian(UInt16(54321))
        reply.append(external)
        XCTAssertEqual(reply.count, 60)

        let parsed = PortMapWire.PCP.parseMapResponse(reply)
        XCTAssertEqual(parsed?.result, 0)
        XCTAssertEqual(parsed?.lifetime, 7200)
        XCTAssertEqual(parsed?.nonce, nonce, "the nonce is what ties a renewal to its mapping")
        XCTAssertEqual(parsed?.internalPort, 61423)
        XCTAssertEqual(parsed?.externalPort, 54321)
        XCTAssertEqual(PortMapWire.ipv4(fromMappedIPv6: parsed!.externalAddress), "203.0.113.9")
    }

    /// A router that predates PCP cannot answer in PCP: it sends a NAT-PMP
    /// unsupported-version error instead, which is the signal to fall back rather
    /// than a packet to parse.
    func testAGatewayThatOnlySpeaksNATPMPSaysSoInNATPMP() {
        let old = Data([0, 128, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(PortMapWire.PCP.saysUseNATPMP(old))
        XCTAssertNil(PortMapWire.PCP.parseMapResponse(old))
    }

    func testAPCPResponseIsNotMistakenForARequestToFallBackFrom() {
        var reply = Data([2, 1 | 0x80, 0, 0])
        reply.append(Data(repeating: 0, count: 56))
        XCTAssertFalse(PortMapWire.PCP.saysUseNATPMP(reply))
    }

    func testCarrierGradeNATIsNamedRatherThanReportedAsAGenericFailure() {
        XCTAssertTrue(PortMapWire.PCP.Result.cannotProvideExternal.message
            .contains("carrier-grade NAT"))
    }

    func testEveryPCPResultCodeInTheRFCIsNamed() {
        for code in 0...13 {
            let result = PortMapWire.PCP.Result(rawValue: UInt8(code))
            XCTAssertNotNil(result, "result \(code) is in the RFC and should be named")
            XCTAssertFalse(result!.message.isEmpty)
        }
    }

    // MARK: - Addresses

    func testAnIPv4AddressRoundTripsThroughTheFormPCPWants() {
        for address in ["192.168.1.20", "10.0.0.1", "203.0.113.9", "255.255.255.255", "0.0.0.0"] {
            let wrapped = PortMapWire.mappedIPv6(fromIPv4: address)
            XCTAssertEqual(wrapped?.count, 16, address)
            XCTAssertEqual(PortMapWire.ipv4(fromMappedIPv6: wrapped!), address)
        }
    }

    func testSomethingThatIsNotAnIPv4AddressIsRefused() {
        XCTAssertNil(PortMapWire.mappedIPv6(fromIPv4: "192.168.1"))
        XCTAssertNil(PortMapWire.mappedIPv6(fromIPv4: "not an address"))
        XCTAssertNil(PortMapWire.mappedIPv6(fromIPv4: "192.168.1.999"))
    }

    /// A real IPv6 address is not a wrapped IPv4 one, and reading it as though it
    /// were would publish four of its bytes as an address.
    func testARealIPv6AddressIsNotReadAsAWrappedIPv4One() {
        let six = PortMapWire.ipv6Bytes(from: "2001:db8::1")!
        XCTAssertNil(PortMapWire.ipv4(fromMappedIPv6: six))
    }

    func testAnIPv6AddressParsesIncludingTheScopeItArrivesWith() {
        XCTAssertEqual(PortMapWire.ipv6Bytes(from: "2001:db8::1")?.count, 16)
        XCTAssertEqual(PortMapWire.ipv6Bytes(from: "fe80::1%en0"),
                       PortMapWire.ipv6Bytes(from: "fe80::1"),
                       "an interface address arrives with its scope attached")
        XCTAssertNil(PortMapWire.ipv6Bytes(from: "192.168.1.20"))
        XCTAssertNil(PortMapWire.ipv6Bytes(from: "nonsense"))
    }

    func testANonceIsTwelveBytesAndNotTheSameTwice() {
        XCTAssertEqual(PortMapWire.newNonce().count, 12)
        XCTAssertNotEqual(PortMapWire.newNonce(), PortMapWire.newNonce())
    }

    /// A slice of a `Data` keeps its parent's indices, so a parser that reads
    /// `self[0]` reads the wrong byte or traps. Every response here arrives as a
    /// slice of a receive buffer.
    func testAResponseSlicedOutOfALargerBufferParsesTheSameWay() {
        var buffer = Data(repeating: 0xEE, count: 40)
        buffer.append(Data([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 9]))
        let slice = buffer.subdata(in: 40..<52)
        XCTAssertEqual(PortMapWire.NATPMP.parseExternalAddressResponse(slice)?.address,
                       "203.0.113.9")
        let suffix = buffer[40...]
        XCTAssertEqual(PortMapWire.NATPMP.parseExternalAddressResponse(suffix)?.address,
                       "203.0.113.9")
    }
}

/// What the internet says this Mac's address is.
final class StunWireTests: XCTestCase {

    func testABindingRequestIsTwentyBytesWithTheCookieInIt() {
        let transaction = Data(repeating: 0x11, count: 12)
        let data = StunWire.request(transaction: transaction)!
        XCTAssertEqual(data.count, 20)
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[0..<2]), [0x00, 0x01], "binding request")
        XCTAssertEqual(Array(bytes[2..<4]), [0x00, 0x00], "no attributes")
        XCTAssertEqual(Array(bytes[4..<8]), [0x21, 0x12, 0xA4, 0x42], "the magic cookie")
        XCTAssertEqual(Array(bytes[8..<20]), [UInt8](transaction))
    }

    func testTheXoredAddressIsUnmasked() {
        let transaction = Data(repeating: 0x11, count: 12)
        let reply = successResponse(address: "203.0.113.9", port: 61423, transaction: transaction)
        let found = StunWire.reflexiveAddress(in: reply, transaction: transaction)
        XCTAssertEqual(found?.host, "203.0.113.9")
        XCTAssertEqual(found?.port, 61423)
        XCTAssertFalse(found?.isIPv6 ?? true)
    }

    /// UDP delivers whatever arrives, including a late answer to a request that
    /// was given up on — measured through an interface that may since have gone.
    func testAnAnswerToADifferentQuestionIsIgnored() {
        let asked = Data(repeating: 0x11, count: 12)
        let reply = successResponse(address: "203.0.113.9", port: 1,
                                    transaction: Data(repeating: 0x22, count: 12))
        XCTAssertNil(StunWire.reflexiveAddress(in: reply, transaction: asked))
    }

    func testAReplyWithoutTheCookieIsNotSTUN() {
        let transaction = Data(repeating: 0x11, count: 12)
        var reply = successResponse(address: "203.0.113.9", port: 1, transaction: transaction)
        reply[4] = 0x00
        XCTAssertNil(StunWire.reflexiveAddress(in: reply, transaction: transaction))
    }

    func testAnIPv6ReflexiveAddressIsUnmaskedWithTheTransactionId() {
        let transaction = Data((0..<12).map { UInt8($0 + 1) })
        let reply = successResponse(ipv6: "2001:db8::1", port: 61423, transaction: transaction)
        let found = StunWire.reflexiveAddress(in: reply, transaction: transaction)
        XCTAssertEqual(found?.host, "2001:db8::1")
        XCTAssertEqual(found?.port, 61423)
        XCTAssertTrue(found?.isIPv6 ?? false)
    }

    /// The un-XORed form is what a server old enough to send only it uses, and it
    /// is still the truth.
    func testTheLegacyUnmaskedFormIsStillRead() {
        let transaction = Data(repeating: 0x11, count: 12)
        var reply = header(type: 0x0101, transaction: transaction, attributeBytes: 12)
        reply.appendBigEndian(UInt16(0x0001))       // MAPPED-ADDRESS
        reply.appendBigEndian(UInt16(8))
        reply.append(contentsOf: [0, 1])
        reply.appendBigEndian(UInt16(61423))
        reply.append(contentsOf: [203, 0, 113, 9])
        let found = StunWire.reflexiveAddress(in: reply, transaction: transaction)
        XCTAssertEqual(found?.host, "203.0.113.9")
        XCTAssertEqual(found?.port, 61423)
    }

    /// An attribute the parser skips is padded to a multiple of four, and the
    /// padding is not counted in its declared length. Getting that wrong walks
    /// the cursor into the middle of the next attribute.
    func testAnAttributeBeforeTheAddressIsSteppedOverCorrectly() {
        let transaction = Data(repeating: 0x11, count: 12)
        var reply = header(type: 0x0101, transaction: transaction, attributeBytes: 20)
        reply.appendBigEndian(UInt16(0x8022))       // SOFTWARE, an odd length
        reply.appendBigEndian(UInt16(5))
        reply.append(contentsOf: Array("hello".utf8))
        reply.append(contentsOf: [0, 0, 0])         // padded to four
        reply.append(xorMappedAddress(address: "203.0.113.9", port: 61423))
        XCTAssertEqual(StunWire.reflexiveAddress(in: reply, transaction: transaction)?.host,
                       "203.0.113.9")
    }

    func testAnErrorResponseIsAnErrorRatherThanSilence() {
        let transaction = Data(repeating: 0x11, count: 12)
        var reply = header(type: 0x0111, transaction: transaction, attributeBytes: 8)
        reply.appendBigEndian(UInt16(0x0009))
        reply.appendBigEndian(UInt16(4))
        reply.append(contentsOf: [0, 0, 4, 20])     // class 4, number 20 → 420
        XCTAssertEqual(StunWire.errorCode(in: reply), 420)
        XCTAssertNil(StunWire.reflexiveAddress(in: reply, transaction: transaction))
    }

    /// The one thing STUN is here to say that nothing else can: the address the
    /// internet sees is the ISP's own NAT, so forwarding a port achieves nothing
    /// and no retry will change it.
    func testAnAddressInsideTheCarrierNATRangeIsRecognised() {
        XCTAssertTrue(StunWire.Reflexive(host: "100.64.0.1", port: 1, isIPv6: false)
            .isCarrierGradeNAT)
        XCTAssertTrue(StunWire.Reflexive(host: "100.127.255.254", port: 1, isIPv6: false)
            .isCarrierGradeNAT)
        XCTAssertFalse(StunWire.Reflexive(host: "100.63.255.255", port: 1, isIPv6: false)
            .isCarrierGradeNAT, "just below the range")
        XCTAssertFalse(StunWire.Reflexive(host: "100.128.0.0", port: 1, isIPv6: false)
            .isCarrierGradeNAT, "just above it")
        XCTAssertFalse(StunWire.Reflexive(host: "203.0.113.9", port: 1, isIPv6: false)
            .isCarrierGradeNAT)
        XCTAssertFalse(StunWire.Reflexive(host: "2001:db8::1", port: 1, isIPv6: true)
            .isCarrierGradeNAT, "IPv6 has no carrier NAT to be behind")
    }

    // MARK: - Helpers

    private func header(type: UInt16, transaction: Data, attributeBytes: Int) -> Data {
        var data = Data()
        data.appendBigEndian(type)
        data.appendBigEndian(UInt16(attributeBytes))
        data.appendBigEndian(StunWire.magicCookie)
        data.append(transaction)
        return data
    }

    private func xorMappedAddress(address: String, port: UInt16) -> Data {
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        var data = Data()
        data.appendBigEndian(UInt16(0x0020))
        data.appendBigEndian(UInt16(8))
        data.append(contentsOf: [0, 1])
        data.appendBigEndian(port ^ UInt16(StunWire.magicCookie >> 16))
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        data.append(contentsOf: (0..<4).map { octets[$0] ^ cookie[$0] })
        return data
    }

    private func successResponse(address: String, port: UInt16, transaction: Data) -> Data {
        var data = header(type: 0x0101, transaction: transaction, attributeBytes: 12)
        data.append(xorMappedAddress(address: address, port: port))
        return data
    }

    private func successResponse(ipv6: String, port: UInt16, transaction: Data) -> Data {
        var data = header(type: 0x0101, transaction: transaction, attributeBytes: 24)
        data.appendBigEndian(UInt16(0x0020))
        data.appendBigEndian(UInt16(20))
        data.append(contentsOf: [0, 2])
        data.appendBigEndian(port ^ UInt16(StunWire.magicCookie >> 16))
        let mask: [UInt8] = [0x21, 0x12, 0xA4, 0x42] + [UInt8](transaction)
        let raw = [UInt8](PortMapWire.ipv6Bytes(from: ipv6)!)
        data.append(contentsOf: (0..<16).map { raw[$0] ^ mask[$0] })
        return data
    }
}

/// What the Mac tells the phone about reaching it, and in what order the phone
/// should try it.
final class CandidateTests: XCTestCase {

    func testTheLocalAddressIsTriedBeforeAnythingThatLeavesTheBuilding() {
        let mixed = [NimletCandidate(host: "203.0.113.9", port: 61423, reach: .forwarded4, via: "PCP"),
                     NimletCandidate(host: "2001:db8::1", port: 61423, reach: .internet6, via: "en0"),
                     NimletCandidate(host: "192.168.1.20", port: 61413, reach: .local, via: "en0")]
        XCTAssertEqual(CandidateOrder.sorted(mixed).map(\.reach),
                       [.local, .internet6, .forwarded4],
                       "being at your own desk must not pay for a trip through the internet")
    }

    func testTheOrderIsStableSoTheSameListDoesNotReshuffleBetweenPushes() {
        let two = [NimletCandidate(host: "192.168.1.21", port: 61413, reach: .local, via: "en1"),
                   NimletCandidate(host: "192.168.1.20", port: 61413, reach: .local, via: "en0")]
        XCTAssertEqual(CandidateOrder.sorted(two).map(\.host),
                       CandidateOrder.sorted(two.reversed()).map(\.host))
    }

    func testOnlyTheLocalAddressesStayOnThisNetwork() {
        XCTAssertFalse(NimletCandidate(host: "192.168.1.20", port: 1, reach: .local, via: "en0").isRemote)
        XCTAssertTrue(NimletCandidate(host: "2001:db8::1", port: 1, reach: .internet6, via: "en0").isRemote)
        XCTAssertTrue(NimletCandidate(host: "203.0.113.9", port: 1, reach: .forwarded4, via: "PCP").isRemote)
    }

    func testAnIPv6CandidateIsShownInTheBracketsThatMakeItUnambiguous() {
        XCTAssertEqual(NimletCandidate(host: "2001:db8::1", port: 61423,
                                     reach: .internet6, via: "en0").display,
                       "[2001:db8::1]:61423")
        XCTAssertEqual(NimletCandidate(host: "203.0.113.9", port: 61423,
                                     reach: .forwarded4, via: "PCP").display,
                       "203.0.113.9:61423")
    }

    func testAddressesAndThePushKeySurviveTheWire() throws {
        let payload = RemoteAccessPayload(
            isEnabled: true,
            candidates: [NimletCandidate(host: "203.0.113.9", port: 61423, reach: .forwarded4, via: "PCP"),
                         NimletCandidate(host: "relay.example", port: 7443, reach: .relay, via: "relay")],
            pushKey: Data(repeating: 0x7F, count: RemoteAccess.keyLength))
        let line = try NimletCoder.line(HostMessage.remoteAccess(payload))
        guard case .remoteAccess(let decoded) = try NimletCoder.decode(HostMessage.self, from: line) else {
            return XCTFail("not a remoteAccess message")
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.issuedPushKey?.count, 32)
    }

    /// Most pushes carry no key. A phone must not read the absence as "your key
    /// has been withdrawn" and throw away the one it has.
    func testAPushWithNoKeyOffersNoKeyRatherThanAnEmptyOne() {
        XCTAssertNil(RemoteAccessPayload(isEnabled: true).issuedPushKey)
    }

    func testAKeyOfTheWrongLengthIsDiscardedRatherThanStored() {
        let short = RemoteAccessPayload(isEnabled: true, pushKey: Data(repeating: 0, count: 8))
        XCTAssertNil(short.issuedPushKey, "a truncated key opens no push")
    }
}

/// The keys that seal pushes.
final class RemoteKeyTests: XCTestCase {

    func testAPushKeyIsTwoHundredAndFiftySixBits() {
        XCTAssertEqual(NimletTransport.newRemoteKey().count, 32)
    }

    func testTwoPushKeysAreNotTheSameKey() {
        XCTAssertNotEqual(NimletTransport.newRemoteKey(), NimletTransport.newRemoteKey())
    }

    func testAPushKeyIsNotDerivedFromThePairingCode() {
        XCTAssertNotEqual(NimletTransport.newRemoteKey(), NimletTransport.pskData(forCode: "ABC234"))
    }
}

/// Which connections may be handed a push key: only one from this Mac's own
/// network, never one that arrived over the internet-facing path.
final class SameNetworkTests: XCTestCase {

    /// Four addresses from one home /64, which is what a phone, a Mac and a
    /// printer on the same Wi-Fi look like.
    private let mine = ["2001:db8:9010:22c:4db:c58a:74ed:88a7",
                        "2001:db8:9010:22c:410b:d5ba:1c6b:e516"]

    func testTheOrdinaryPrivateRangesAreThisNetwork() {
        for address in ["192.168.0.167", "10.0.0.4", "172.16.9.1", "172.31.255.254", "127.0.0.1"] {
            XCTAssertTrue(PortMapWire.isOnSameNetwork(address, asAnyOf: mine), address)
        }
    }

    func testAPublicIPv4AddressIsNot() {
        for address in ["1.0.0.1", "8.8.8.8", "172.32.0.1", "192.169.0.1"] {
            XCTAssertFalse(PortMapWire.isOnSameNetwork(address, asAnyOf: mine), address)
        }
    }

    /// The carrier's own NAT range is not a home network, and a device appearing
    /// from inside it is not on this link.
    func testTheCarrierNATRangeIsNotTreatedAsPublicEither() {
        XCTAssertTrue(PortMapWire.isPrivateIPv4("100.64.0.1"))
        XCTAssertFalse(PortMapWire.isPrivateIPv4("100.63.255.255"))
        XCTAssertFalse(PortMapWire.isPrivateIPv4("100.128.0.0"))
    }

    func testLinkLocalAndUniqueLocalIPv6AreThisNetworkByDefinition() {
        for address in ["fe80::1", "fe80::5e7d:aeff:feb3:4425%en0", "fd00::1", "fc00::9", "::1"] {
            XCTAssertTrue(PortMapWire.isOnSameNetwork(address, asAnyOf: mine), address)
        }
    }

    /// The case the whole function exists for. Both of these are globally
    /// routable IPv6 addresses and neither looks more local than the other; the
    /// prefix is the only thing that tells them apart.
    func testAGlobalIPv6PeerSharingThePrefixIsThisNetwork() {
        XCTAssertTrue(PortMapWire.isOnSameNetwork("2001:db8:9010:22c:1111:2222:3333:4444",
                                                  asAnyOf: mine))
    }

    func testAGlobalIPv6PeerFromAnotherPrefixIsNot() {
        XCTAssertFalse(PortMapWire.isOnSameNetwork("2001:db8:9010:999:1111:2222:3333:4444",
                                                   asAnyOf: mine),
                       "a different /64 is a different link, one hex digit away")
        XCTAssertFalse(PortMapWire.isOnSameNetwork("2001:4860:4860::8888", asAnyOf: mine))
    }

    func testWithNoAddressesOfItsOwnNoGlobalPeerQualifies() {
        XCTAssertFalse(PortMapWire.isOnSameNetwork("2001:db8:9010:22c::1", asAnyOf: []))
        XCTAssertTrue(PortMapWire.isOnSameNetwork("192.168.1.5", asAnyOf: []),
                      "IPv4 needs nothing to compare against")
    }

    func testNonsenseIsNotThisNetwork() {
        for address in ["", "not an address", "999.999.999.999", "192.168.1"] {
            XCTAssertFalse(PortMapWire.isOnSameNetwork(address, asAnyOf: mine), "'\(address)'")
        }
    }
}
