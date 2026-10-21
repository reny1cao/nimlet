import Foundation
import Network
import CryptoKit
import Security

/// The pairing-code transport, which the `nimlet` command-line tool uses. TLS-PSK
/// derived from the code means a wrong code fails the TLS handshake outright —
/// there is no app-level auth to get wrong.
///
/// This matters more than it looks: the host injects keystrokes into the user's
/// machine, so an unauthenticated listener would be a genuine RCE surface.
///
/// The handshake is only the first gate. Six characters from a 32-character
/// alphabet is about 30 bits, which is not enough on its own, so `HostServer`
/// adds handshake throttling and a per-device approval step and the Mac never
/// injects anything for a device the user has not accepted. See SECURITY.md.
public enum NimletTransport {

    public static func pskData(forCode code: String) -> Data {
        // Deliberately a fixed derivation label, NOT NimletProtocol.version.
        // Salting with the protocol version meant that bumping the wire format
        // silently changed everybody's key: every paired client then failed
        // the TLS handshake, which read as "Wrong pairing code".
        Data(SHA256.hash(data: Data(("mice.psk.k1:" + PairingCode.normalize(code)).utf8)))
    }

    /// The pairing-code listener: what the `nimlet` command-line tool dials.
    /// Phones pair by key (`TrustTransport`).
    public static func parameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let material = pskData(forCode: pairingCode).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("mice".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                material as __DispatchData,
                                                identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return parameters(tls: tls, peerToPeer: true)
    }

    /// TCP under any of Nimlet's TLS: the pairing-code PSK here, and the pinned
    /// keys of `TrustTransport`. One place, so the two cannot drift.
    static func parameters(tls: NWProtocolTLS.Options, peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Pointer deltas are tiny and latency-critical; Nagle would batch them into jitter.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        // Interval and count spelled out: left at zero they are the system's,
        // which can take minutes to declare a peer that walked out of Wi-Fi
        // gone — and until then its socket holds one of the host's eight
        // connection slots. Three missed probes two seconds apart is about the
        // twelve seconds the phone itself waits for a pong.
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        // Keepalive only probes an idle link. A socket with data in flight to
        // a vanished peer — a mirror frame, a status push — retransmits
        // instead, and gives up only on this.
        tcp.connectionDropTime = 20
        // Don't let a half-open connection sit on a listener slot forever.
        tcp.connectionTimeout = 10

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        if !LaunchNetworkPolicy.allowsAwayAccess { params.prohibitedInterfaceTypes = [.cellular] }
        return params
    }

    /// A fresh push key: 256 bits from the system generator.
    public static func newRemoteKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: RemoteAccess.keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Documented to succeed; if it ever does not, a key derived from
            // something weaker would be worse than no key at all.
            fatalError("SecRandomCopyBytes failed with \(status)")
        }
        return Data(bytes)
    }

    /// Six characters, unambiguous alphabet (no O/0, I/1).
    public static func newPairingCode() -> String {
        String((0..<PairingCode.length).map { _ in PairingCode.alphabet.randomElement()! })
    }
}

/// Parsing and validation for the pairing code.
///
/// Worth its own type: a mistyped character is otherwise indistinguishable from
/// a wrong code, a version mismatch and an unreachable host, because all four
/// surface as the same TLS handshake failure.
public enum PairingCode {
    public static let length = 6
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public enum Problem: Equatable, Sendable {
        case empty
        case wrongLength(Int)
        case illegalCharacters(String)

        public var message: String {
            switch self {
            case .empty:
                return "Enter the six-character code shown on your Mac"
            case .wrongLength(let n):
                return "Pairing codes are \(PairingCode.length) characters — this one has \(n)"
            case .illegalCharacters(let chars):
                return "\(chars) can't appear in a pairing code (there is no O, 0, I or 1)"
            }
        }
    }

    /// Upper-cased and stripped of whitespace and separators people type.
    public static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// nil when the code is well-formed. Says nothing about whether it is the
    /// *right* code — only that it could be one.
    public static func validate(_ raw: String) -> Problem? {
        let code = normalize(raw)
        if code.isEmpty { return .empty }
        let legal = Set(alphabet)
        let illegal = code.filter { !legal.contains($0) }
        if !illegal.isEmpty {
            return .illegalCharacters(Array(Set(illegal)).sorted().map(String.init).joined(separator: ", "))
        }
        if code.count != length { return .wrongLength(code.count) }
        return nil
    }

    public static func isValid(_ raw: String) -> Bool { validate(raw) == nil }
}
