import Foundation
import CryptoKit
import Network
import Security

// The trust layer that replaces the pairing-code PSK.
//
// What the PSK could not give, and why it has to go before any relay:
//
// - **Forward secrecy.** Apple's external-PSK path negotiates plain PSK
//   (0x00A8, no Diffie-Hellman), so anybody who records a session decrypts all
//   of it the day the key leaks — and the LAN key is thirty bits, so "the day"
//   is any day. The away key is issued over that same channel, so it is only
//   as strong as the code. A relay in the path makes recording free.
// - **Identity.** Every LAN device holds the same key, and the Mac approves a
//   device id the phone states about itself.
//
// What replaces it: each end has a long-lived P-256 key wrapped in a
// self-signed certificate, both ends pin the other's key, and the link is
// TLS 1.3 with mutual authentication — ECDHE, so a recording is worthless,
// and the device id is the hash of a key the phone proves it holds in the
// handshake itself. The certificates carry nothing but the key: no CA, no
// names that mean anything, no expiry anyone checks. Pinning the key is the
// whole of the trust decision, and it is made in `TrustTransport`'s verify
// block, before a byte of Nimlet's own protocol.
//
// First contact — a phone the Mac has never seen — is the pairing invitation:
// the QR code carries the Mac's key fingerprint and a one-time secret, the
// phone pins the first and proves the second bound to this very TLS session
// (`PairingProof`). See docs/architecture/trust-layer.md.

/// A long-lived identity for one end of the link.
public struct TrustIdentity: @unchecked Sendable {
    public let privateKey: P256.Signing.PrivateKey
    /// A self-signed certificate around `privateKey`'s public half, in DER.
    public let certificateDER: Data
    /// The identity in the form Network.framework presents in a handshake.
    /// Built once: every dial and every second socket asks for it, and
    /// rebuilding the key, certificate and identity objects each time is work
    /// that never changes its answer.
    public let secIdentity: sec_identity_t

    /// Makes a fresh certificate around an existing key. The certificate is
    /// a wrapper TLS insists on and nothing more, so it is rebuilt at launch
    /// rather than stored: only the key has to persist.
    public init(privateKey: P256.Signing.PrivateKey, commonName: String = "nimlet") throws {
        self.privateKey = privateKey
        let der = try SelfSignedCertificate.make(for: privateKey, commonName: commonName)
        self.certificateDER = der
        self.secIdentity = try Self.makeIdentity(privateKey: privateKey, certificateDER: der)
    }

    /// This end's identity from the Keychain, made and stored on first use.
    /// Nil only if the Keychain will not keep the key; the caller says so.
    public static func loadOrCreate(account: String, commonName: String) -> TrustIdentity? {
        if let raw = SecretStore.read(service: SecretStore.trustService, account: account),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return try? TrustIdentity(privateKey: key, commonName: commonName)
        }
        let key = P256.Signing.PrivateKey()
        guard SecretStore.write(key.rawRepresentation, service: SecretStore.trustService, account: account) else {
            return nil
        }
        return try? TrustIdentity(privateKey: key, commonName: commonName)
    }

    /// What the other end pins.
    public var fingerprint: TrustFingerprint { TrustFingerprint(publicKey: privateKey.publicKey) }

    private static func makeIdentity(privateKey: P256.Signing.PrivateKey,
                                     certificateDER: Data) throws -> sec_identity_t {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateWithData(privateKey.x963Representation as CFData,
                                             attributes as CFDictionary, &error) else {
            throw TrustError.key(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw TrustError.certificate
        }
        guard let identity = SecIdentityCreate(nil, certificate, key),
              let wrapped = sec_identity_create(identity) else {
            throw TrustError.identity
        }
        return wrapped
    }
}

public enum TrustError: Error, Equatable {
    case key(String)
    case certificate
    case identity
}

/// The hash of a public key: what a device *is*, as far as the other end is
/// concerned. SHA-256 over the uncompressed point, so it can be computed from
/// a certificate without parsing one — Security hands back the point.
public struct TrustFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(publicKey: P256.Signing.PublicKey) {
        bytes = Data(SHA256.hash(data: publicKey.x963Representation))
    }

    public init?(bytes: Data) {
        guard bytes.count == SHA256.byteCount else { return nil }
        self.bytes = bytes
    }

    /// The fingerprint of the key inside a certificate, or nil for anything
    /// that is not a P-256 key — which no Nimlet peer ever presents.
    public init?(certificate: SecCertificate) {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else { return nil }
        self.init(publicKey: publicKey)
    }

    /// Stable, URL-safe, and the form a device id takes from now on.
    public var description: String { bytes.base64URLEncoded }

    public init?(_ text: String) {
        guard let data = Data(base64URLEncoded: text) else { return nil }
        self.init(bytes: data)
    }

    /// Short enough to read aloud and compare on two screens: the first 40
    /// bits as eight characters of the pairing alphabet. Not a security
    /// boundary on its own — the full fingerprint is what is pinned — but what
    /// a person checks when a QR code is not available.
    public var shortCode: String {
        var value: UInt64 = 0
        for byte in bytes.prefix(5) { value = value << 8 | UInt64(byte) }
        let alphabet = PairingCode.alphabet
        return String((0..<8).reversed().map { alphabet[Int((value >> (UInt64($0) * 5)) & 31)] })
    }
}

/// TLS parameters for the trust layer: TLS 1.3 only, both ends present a
/// certificate, and each pins the other's key.
public enum TrustTransport {

    /// - Parameters:
    ///   - identity: this end's identity.
    ///   - accepts: the trust decision, given the peer's fingerprint. The
    ///     phone passes "is this the Mac I paired with"; the Mac passes "is
    ///     this an approved device, or is a pairing invitation open".
    ///   - peerToPeer: as for the PSK listener — on for the LAN, where AWDL is
    ///     how a phone reaches a Mac without sharing a network.
    ///   - serverName: what the ClientHello names, for a dial through the
    ///     connect relay, which routes on it (`RelayRoute.serverName`). Not
    ///     checked by anybody: the verify block pins the key.
    public static func parameters(identity: TrustIdentity,
                                  accepts: @escaping @Sendable (TrustFingerprint) -> Bool,
                                  peerToPeer: Bool = true,
                                  serverName: String? = nil,
                                  applicationProtocol: String? = nil) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let serverName { sec_protocol_options_set_tls_server_name(options, serverName) }
        if let applicationProtocol { sec_protocol_options_add_tls_application_protocol(options, applicationProtocol) }
        sec_protocol_options_set_local_identity(options, identity.secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        // A server does not ask for a client certificate unless told to, and
        // a phone that is never asked never proves which key it holds.
        sec_protocol_options_set_peer_authentication_required(options, true)
        // No resumption, in either direction. A resumed TLS 1.3 session skips
        // the certificate exchange and with it the verify block — so a phone
        // revoked after its first connection could come back on a ticket from
        // before, and the Mac would never be asked whether it still trusts
        // that key. Without 0-RTT a resumed handshake takes the same one round
        // trip as a full one, so this costs a few signatures and nothing more.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            complete(peerFingerprint(of: trust).map(accepts) ?? false)
        }, verifyQueue)
        return NimletTransport.parameters(tls: tls, peerToPeer: peerToPeer)
    }

    private static func metadata(of connection: NWConnection) -> sec_protocol_metadata_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
            .securityProtocolMetadata
    }

    /// The verify block's queue. Its own, so a trust decision never waits on
    /// pointer traffic.
    private static let verifyQueue = DispatchQueue(label: "com.renyicao.mice.trust.verify")

    static func peerFingerprint(of trust: sec_trust_t) -> TrustFingerprint? {
        let ref = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(ref) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return TrustFingerprint(certificate: leaf)
    }

    /// The fingerprint the peer of an established connection proved it holds.
    /// This, not anything the peer says afterwards, is who it is.
    public static func peerFingerprint(of connection: NWConnection) -> TrustFingerprint? {
        guard let metadata = metadata(of: connection) else { return nil }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        return leaf.flatMap(TrustFingerprint.init(certificate:))
    }

    /// A secret both ends of this one TLS session can derive and nobody else
    /// can (RFC 8446 §7.5). Binding a proof to it means a proof captured on one
    /// connection is worthless on any other.
    public static func exporter(of connection: NWConnection, label: String) -> Data? {
        guard let metadata = metadata(of: connection) else { return nil }
        let secret = label.withCString { cLabel in
            sec_protocol_metadata_create_secret(metadata, strlen(cLabel), cLabel, SHA256.byteCount)
        }
        guard let secret else { return nil }
        return Data(secret as DispatchData)
    }

    /// The negotiated protocol version, for diagnostics and for the test that
    /// pins it at 1.3.
    public static func negotiatedVersion(of connection: NWConnection) -> tls_protocol_version_t? {
        metadata(of: connection).map(sec_protocol_metadata_get_negotiated_tls_protocol_version)
    }
}

/// What a phone shows the Mac to be let in the first time: proof that it read
/// the one-time secret off this Mac's screen, bound to this TLS session and to
/// the key the phone just authenticated with.
///
/// Bound to the session so a proof cannot be replayed on another connection;
/// bound to the phone's key so a proof cannot be lifted onto another device.
/// The secret is 128 bits from a QR code, so there is nothing to brute force
/// offline even for somebody who could see the exporter — and nobody can,
/// because it is derived from an ECDHE session they are not party to.
public enum PairingProof {
    public static let exporterLabel = "EXPORTER-nimlet-pairing-v1"
    public static let secretLength = 16

    public static func make(secret: Data, exporter: Data, device: TrustFingerprint) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(exporter: exporter, device: device),
                                             using: SymmetricKey(data: secret)))
    }

    /// Constant time, by way of CryptoKit.
    public static func verify(_ proof: Data, secret: Data, exporter: Data, device: TrustFingerprint) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message(exporter: exporter, device: device),
                                               using: SymmetricKey(data: secret))
    }

    /// One construction for both ends, so the two can never disagree.
    private static func message(exporter: Data, device: TrustFingerprint) -> Data {
        Data("nimlet.pair.1".utf8) + exporter + device.bytes
    }

    public static func newSecret() -> Data {
        Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }
}

/// The Mac's side of an invitation: one secret, good for one phone, for a
/// limited time.
///
/// Single use because the QR code is on a screen, and a screen can be
/// photographed or shared on a call; ten minutes because that is longer than
/// pairing takes and shorter than leaving a code up by accident lasts.
public struct PairingWindow: Sendable {
    public static let lifetime: TimeInterval = 600

    public private(set) var secret: Data?
    public private(set) var expires: Date?

    public init() {}

    public var isOpen: Bool { isOpen(at: Date()) }

    public func isOpen(at now: Date) -> Bool {
        guard secret != nil, let expires else { return false }
        return now < expires
    }

    /// Opens a fresh window, replacing any open one: a new QR code makes the
    /// old one worthless.
    public mutating func open(at now: Date = Date()) -> Data {
        let fresh = PairingProof.newSecret()
        secret = fresh
        expires = now.addingTimeInterval(Self.lifetime)
        return fresh
    }

    public mutating func close() {
        secret = nil
        expires = nil
    }

    /// Whether `proof` was made with the open secret for this session and this
    /// device. A good proof closes the window; a bad one leaves it open, so a
    /// stranger guessing cannot shut the person actually pairing out — the
    /// connection throttle is what bounds the guessing.
    public mutating func redeem(_ proof: Data, exporter: Data, device: TrustFingerprint,
                                at now: Date = Date()) -> Bool {
        guard isOpen(at: now), let secret,
              PairingProof.verify(proof, secret: secret, exporter: exporter, device: device) else { return false }
        close()
        return true
    }
}

/// What the Mac's QR code says: which key to pin, the one-time secret, and
/// where to dial. A URL so the system camera can open the app with it.
public struct PairingInvitation: Equatable, Sendable {
    public var host: TrustFingerprint
    public var secret: Data
    public var name: String
    /// Addresses worth trying, "host:port", best first. Optional: on the
    /// LAN, Bonjour finds the Mac anyway.
    public var addresses: [String]

    public static let scheme = "nimlet"

    public init(host: TrustFingerprint, secret: Data, name: String, addresses: [String] = []) {
        self.host = host
        self.secret = secret
        self.name = name
        self.addresses = addresses
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: host.description),
            URLQueryItem(name: "s", value: secret.base64URLEncoded),
            URLQueryItem(name: "n", value: name),
        ] + addresses.map { URLQueryItem(name: "a", value: $0) }
        return components.url!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == "pair" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == "1",
              let host = value("h").flatMap(TrustFingerprint.init),
              let secret = value("s").flatMap({ Data(base64URLEncoded: $0) }),
              secret.count == PairingProof.secretLength else { return nil }
        self.host = host
        self.secret = secret
        self.name = value("n") ?? "Mac"
        self.addresses = items.filter { $0.name == "a" }.compactMap(\.value)
    }
}

// MARK: - The certificate

/// The smallest X.509 certificate TLS will carry: a v3 TBS with no
/// extensions, an ECDSA P-256 key and an ECDSA-SHA256 self-signature.
///
/// Built by hand because neither platform has an API to make one, and the
/// alternative is a dependency for forty lines of DER. Nothing reads its
/// names or dates — the verify block pins the key — but they are well-formed,
/// because BoringSSL parses the whole thing before it gets that far.
enum SelfSignedCertificate {
    static func make(for key: P256.Signing.PrivateKey, commonName: String,
                     now: Date = Date()) throws -> Data {
        let name = DER.sequence(DER.set(DER.sequence(DER.oidCommonName + DER.utf8String(commonName))))
        let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-86_400))
                                    + DER.utcTime(Date(timeIntervalSince1970: 2_524_607_999))) // 2049-12-31
        let publicKeyInfo = DER.sequence(DER.sequence(DER.oidECPublicKey + DER.oidP256)
                                         + DER.bitString(key.publicKey.x963Representation))
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7f
        serial[0] |= 0x01
        let tbs = DER.sequence(
            DER.contextExplicit(0, DER.integer([2]))   // v3
            + DER.integer(serial)
            + DER.sequence(DER.oidECDSAWithSHA256)
            + name
            + validity
            + name
            + publicKeyInfo
        )
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence(tbs + DER.sequence(DER.oidECDSAWithSHA256) + DER.bitString(signature))
    }
}

/// Just enough DER to write the certificate above.
enum DER {
    static let oidECDSAWithSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let oidECPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let oidP256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let oidCommonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])

    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        let count = value.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = [UInt8]()
            var remaining = count
            while remaining > 0 { length.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        out.append(value)
        return out
    }

    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }
    static func contextExplicit(_ tag: UInt8, _ content: Data) -> Data { tlv(0xA0 | tag, content) }
    static func utf8String(_ text: String) -> Data { tlv(0x0C, Data(text.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    /// A positive INTEGER: a leading zero is added if the top bit is set.
    static func integer(_ bytes: [UInt8]) -> Data {
        var body = Array(bytes.drop { $0 == 0 })
        if body.isEmpty { body = [0] }
        if body[0] & 0x80 != 0 { body.insert(0, at: 0) }
        return tlv(0x02, Data(body))
    }

    /// UTCTime, which covers every date this ever writes (before 2050).
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
