# Trust layer: replacing the pairing-code PSK

Status: **wired into both apps** (protocol 25: phones pair by key only). Host: `NimletHost/HostTrust.swift`,
`PairWindow.swift`, and the trust and away listeners in `HostServer`. Phone:
`NimletRemote/PhoneTrust.swift` and the trust dials in `NimletClient`. Tests:
`TrustTransportTests` and `TrustPairingTests` (loopback, macOS), plus the
pairing tests in `NimletConnectionTests` (real `NimletClient` against a trust
listener). Not yet verified on a physical iPhone or against the real Mac app.
This is gate 2 of the connectivity plan; a relay (gate 3) must not ship before
it.

## Why

| Problem today | Consequence |
|---|---|
| TLS-PSK negotiates plain PSK `0x00A8`; Apple's external-PSK path offers no (EC)DHE suite | No forward secrecy: a recorded session decrypts the day the key leaks |
| LAN key = `SHA256(salt + 6-char code)`, ~30 bits, shared identity `"mice"` | A recorded handshake is offline-brute-forceable. AWDL means "recorded" = anyone in radio range |
| The 256-bit away key is issued over that LAN channel | Its effective strength is the code's 30 bits; push sealing uses the same key |
| Approval is keyed by a self-reported UUID; side sockets are tied to the control socket only by that string | Identity is a claim, not a proof |

A relay makes recording free, so this is a prerequisite, not hardening.

## Design

- Each end holds a long-lived **P-256 key**. The certificate around it is
  self-signed, minimal, rebuilt at launch, and never trusted for anything but
  carrying the key (`SelfSignedCertificate`).
- **TLS 1.3 only, mutual authentication.** Each side's verify block pins the
  peer's key fingerprint (`TrustTransport.parameters`). ECDHE gives forward
  secrecy; the client certificate proves which key the phone holds.
- **Device id = key fingerprint** (`TrustFingerprint`, SHA-256 of the
  uncompressed point, base64url). The host reads it from the handshake
  (`peerFingerprint(of:)`) and ignores whatever `hello` claims.
- **Revocation** removes the fingerprint from the accepted set: the handshake
  fails, on every listener and every socket type.
- **Side channels** (panel, listen, upload, still) present the same
  certificate, so each socket is bound to the device cryptographically.

Verified on loopback against Apple's stack: TLS 1.3 negotiated; both ends see
the other's fingerprint; the exporter matches on both ends and differs per
session; wrong Mac, unknown phone and certificate-less phone are all refused.

## Pairing

Decision: **existing phones re-pair once by scanning a QR code.** Migrating
over the old channel would carry the 30-bit weakness into the new trust, and
the user base is TestFlight seed testers.

1. Mac menu → "Pair a phone" shows a QR code for a `PairingInvitation`:
   `nimlet://pair?v=1&h=<Mac fingerprint>&s=<128-bit secret>&n=<name>&a=<addr>…`.
   Single use, expires after 10 minutes.
2. The system Camera opens the URL in the app — no scanner UI needed, just the
   URL scheme.
3. The phone pins `h`, dials (Bonjour, then `a` addresses), and on `.ready` sends
   `pair(proof, deviceName)` where
   `proof = HMAC(secret, "nimlet.pair.1" ‖ exporter ‖ phoneFingerprint)` and the
   exporter label is `EXPORTER-nimlet-pairing-v1` (`PairingProof`).
4. While an invitation is open, the host's verify block admits unknown
   fingerprints, but such a connection may send exactly one message: a valid
   `pair`. Anything else, or a wrong proof, closes it and counts toward the
   existing throttle. A valid proof approves the device directly — scanning the
   Mac's screen is the physical-presence check the approval prompt stood for.
5. **No camera fallback (not built):** the phone would dial trust-on-first-use,
   both screens would show `TrustFingerprint.shortCode` (8 chars), and the user
   would compare them before typing the 6-char code as the secret. Without that
   comparison, a MITM could brute-force the code offline from its own
   exporter, so the comparison would be mandatory.

## How it is wired

Host:
- `HostTrust`: load/create the Mac key in the Keychain (new `SecretStore`
  service), accepted set = approved fingerprints, plus the open invitation.
- The trust listener on TCP 61433 (`mice.trustPort`), peer-to-peer on, Bonjour
  `_nimlet._tcp` under the same instance name as `_mice._tcp`, with TXT `fp`.
  The away listener uses the same parameters with peer-to-peer off and never
  pairs. The pairing-code PSK listener remains only for the `nimlet` tool.
- The push key (`AwayKeys`) seals pushes and is issued only over the trust
  listener, from this network.
- TLS resumption and tickets are off, so a revoked key cannot come back on an
  old session.
- A socket that proved an approved key and closed before `hello` is not
  counted towards the handshake lockout: it is a phone's race loser, not a
  guess.

Phone:
- The key is in the Keychain (`ThisDeviceOnly`, `AfterFirstUnlock`). Moving it
  into the Secure Enclave is a follow-up: `SecIdentityCreate` with an SE key ref
  needs a device test.
- A new iPhone is a new device, whatever Apple Account it is signed in to.
  Restoring from a backup or Quick Start carries the preferences (pins,
  remembered Macs) and not the key, so the pins record the key that made them
  (`mice.trust.owner.v1`), and pins made by another key are dropped at launch:
  the Macs stay listed as "Needs to pair again". The phone pairs by scanning
  the code in the app or with the Camera, and the Mac's pairing window then
  offers to remove the phones it may have replaced, which otherwise stay
  approved.
- The `nimlet://pair` URL handler, and one pinned Mac per remembered host. A
  phone only ever dials by key: its Bonjour `_nimlet._tcp` service and the
  trust candidates are raced, staggered by 300 ms, and the first handshake to
  finish wins. A key refusal is a verdict only once every address has
  answered, because a stale address may belong to another Mac now.
- TLS 1.3 detail: the client finishes the handshake **before** the server has
  judged its certificate, so a revoked phone sees `.ready` and then an immediate
  close. "Ready, then closed before `welcome`" has to be reported as
  revoked or not paired, not as a network failure.

Protocol 24 added `pair` (client→host) and `pairResult` (host→client). Protocol
25 makes `RemoteAccessPayload` carry only the trust listeners' addresses and the
push key, and requires both ends to speak the same version.
