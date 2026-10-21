# Security

## Reporting a vulnerability

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/reny1cao/nimlet/security/advisories/new),
or email **support@nimlet.app** with `Nimlet security` in the subject line.
Please do not open a public issue first.

Nimlet is maintained by one person outside working hours, so the commitment here
is deliberately small enough to keep: an acknowledgement within **7 days**, and
an assessment — whether it will be fixed, and roughly when — within **30 days**.
If you have heard nothing after 7 days, assume the mail went astray and send it
again rather than assuming you were ignored.

There is no bounty. Fixes land on `main`; there are no maintained release
branches, because there has not yet been a release.

## What an attacker who wins actually gets

Nimlet exists to synthesise keyboard and mouse events on a Mac. Anything that can
drive it can:

- type arbitrary text into whatever has keyboard focus — including a shell
  prompt — and press Return on it;
- move and click the pointer anywhere on any attached display;
- read the names of the configured targets and the Mac's host name.

Approved devices can also request screen previews, screenshots and the Mac's
system audio. Nimlet has no direct filesystem or clipboard read command, but
something that can type into a terminal can type a command that
sends whatever it likes wherever it likes. Treat a successful attack on Nimlet as
full user-level compromise of the Mac, and assume the Accessibility grant Nimlet
needs is the mechanism rather than an obstacle.

## Pairing by key

Phones pair by key. The Mac's **trust listener** (TCP 61433, Bonjour
`_nimlet._tcp`) is how a phone reaches it, and the away listener described
below works the same way:

- Each end holds a P-256 key: the Mac's and the phone's are both in the
  Keychain. The certificates around the keys are self-signed and carry nothing
  else. Both ends pin the other's key in the TLS verify block, and the
  handshake is **TLS 1.3 with mutual authentication**. ECDHE gives forward
  secrecy, so a recorded session stays unreadable even if a key leaks later.
  The pairing-code PSK cannot offer that: it negotiates plain PSK, `0x00A8`.
- **The device id is the hash of the phone's key**, read from the handshake.
  Whatever a phone's `hello` claims is replaced with it, so on this listener a
  phone cannot pose as another device.
- **Pairing is a QR code** shown by *Pair a Phone…* in the menu. It contains the
  Mac's key fingerprint and a 128-bit one-time secret, works once, and expires
  after ten minutes or when the window closes. The phone pins the fingerprint,
  so its very first handshake already authenticates the Mac. It then proves it
  holds the secret with an HMAC bound to the session's TLS exporter and to its
  own key. That proof cannot be replayed on another connection or moved to
  another device. A valid proof approves the device directly, because reading
  the code off the Mac's screen is the physical presence the approval prompt
  stood for.
- While an invitation is open, an unknown key may complete the handshake on the
  trust listener, but the only thing it may send is `pair`. The away listener
  never pairs.
- **Revoking a device** removes its key from the accepted set. Its next handshake
  fails on every listener, and TLS session resumption is off, so it cannot come
  back on an old session either.
- Each paired phone is also issued a 256-bit **push key**, over the LAN only.
  It seals pushes (see below) and opens nothing.

The pairing code opens only the **code listener**, which the `nimlet`
command-line tool on this Mac uses. No phone dials it.

## Three listeners, and only one of them is on the internet

| | Trust listener | Away listener | Code listener |
|---|---|---|---|
| Port | 61433 | 61423 | 61413 |
| On by default | yes | **no** | yes |
| Who uses it | phones paired by key | phones paired by key | the `nimlet` command-line tool |
| Credential | a P-256 key per device, pinned both ways | the same | the pairing code, ~30 bits, shared |
| Advertised | Bonjour, and peer-to-peer Wi-Fi | not at all | Bonjour, and peer-to-peer Wi-Fi |
| Reachable from | this network, radio range, and a VPN overlay (Tailscale) | wherever the router forwards it from, and the relay | this network and radio range only |
| Unknown key | **fails the handshake**, unless an invitation is open | **fails the handshake**, always | completes the handshake, then waits for approval |

"This network" is enforced, not assumed. A listener bound to a port is bound
on every interface, and a Mac with a global IPv6 address — most homes have
one — would otherwise answer on the trust and code ports from anywhere the
router lets an inbound packet through. So both LAN listeners refuse, before
any handshake, a peer whose address is not on one of this Mac's own networks:
a private IPv4 address, a link-local or unique-local IPv6 one, loopback, or a
global IPv6 address sharing a /64 with one of the Mac's own. The away
listener is the one built to face the internet, and the only one that does.

**A VPN overlay counts as this network for the trust listener, and not for the
code listener.** Phones are documented to reach the Mac over Tailscale, and
the trust listener gives a tailnet peer exactly what it gives a Wi-Fi peer:
a pinned-key handshake, a chance to redeem an open pairing invitation, and —
with away access on — a push key. The overlay authenticates its peers, and
the pairing proof is bound to a secret read off the Mac's screen either way.
The code listener is thirty bits behind a throttle, used only by the `nimlet`
tool on this Mac, and a tailnet of unknown size is not a place to offer that:
an overlay address is refused there. If your tailnet has peers you do not
trust with a connection attempt at all, Tailscale's own ACLs are the place to
close the trust and away ports to them.

The away listener never pairs, so the only keys it lets in are ones the user
paired on this network. Revoking a device removes its key from the accepted set:
a revoked phone cannot open a socket at all, rather than opening one and being
turned away.

A push key is only ever issued over the trust listener, from this network, to a
phone paired by key. Nothing is ever handed out over the away path.

**What this does not defend against.** Away access exposes a port that, given a
valid key, types into your Mac. If a phone holding a key is stolen and unlocked,
the thief has that. The key is in the phone's Keychain as
`AfterFirstUnlockThisDeviceOnly`, so it is not carried to the user's other
devices by iCloud Keychain and is not readable with the phone off — but a
running, unlocked phone with Nimlet on it is a running, unlocked phone with Nimlet
on it. Revoke it from the menu bar to close its current sockets and remove its push key.

**And the honest operational caveat.** Nimlet asks your router to forward a port
using PCP, NAT-PMP or UPnP. None of those is authenticated — anything on your
network can ask your router for a port, and that has been true of every home
network for twenty years — so this is not a new weakness, but it is worth
knowing that the request Nimlet makes is one any program on your LAN could make.
What is behind the port is the part that is defended.

## The pairing code is about 30 bits

The code opens only the code listener, which the `nimlet` command-line tool uses.
It is six characters from a 32-character alphabet — 32⁶, or 1,073,741,824
possibilities, which is exactly 30 bits. It is the entire input to the TLS-PSK
key derivation, so guessing it *is* the attack; there is no second factor
underneath. Thirty bits is not a lot, and this document would be worth nothing
if it claimed otherwise.

Four things stand behind it, and all four are shipped:

**A wrong code fails the TLS handshake itself.** There is no login form, no
bearer token, no application-level check that could be bypassed — the key
derived from the code either completes the handshake or it does not. It also
means nothing the tool sends crosses the LAN in the clear.

**Guessing is throttled per source address.** The third consecutive failed
handshake from an address costs two seconds, and the delay doubles from there
to a five-minute ceiling. An address is forgotten again after an hour without a
failure.

**Concurrency is capped.** The listener accepts at most eight connections at
once, and a connection that has not identified itself within ten seconds is
dropped — so holding sockets open is not a way around the cap.

**Nothing is injected until the user says yes.** Completing the handshake buys
a device a socket and a status message and nothing else. Until its device id is
approved from the menu bar on the Mac, every pointer move, click, keystroke and
delivery is refused. A device the user rejects is remembered as rejected, so it
cannot reconnect a minute later looking like a stranger who has never been
ruled on.

**And nothing is read out either.** The three channels that carry something
*from* the Mac — the panel mirror, a screenshot, and the audio a phone asks to
listen to — each arrive on a socket of their own and say who they are on their
own handshake, because none of them ever sends `hello`. Each is refused on the
same terms and with the same device id. That is deliberate: a live picture of
the screen, or the system audio playing on the Mac, is not less
sensitive than a keystroke, and a channel that skipped the approval check would
be a way to watch and listen to a Mac without ever typing into it. Audio has a
second switch as well — **Let phones listen** in the menu bar — for rooms where
the answer is no regardless of whose phone is asking.

Together those make remote brute force impractical. They are not why you should
feel safe, though — this is:

## The push relay sees a device token and ciphertext

Notifications reach a phone that iOS has frozen only through APNs, and APNs is
addressed with a credential belonging to the developer account rather than to
you or your Mac. Shipping that credential inside the Mac app would hand every
copy the ability to push to every other user's phone, so one service holds it.

That service is the only part of Nimlet that is not your own machine, and it is
given as little as the design allows:

- **The notification is sealed before it leaves the Mac**, with AES-GCM under
  the per-device 256-bit push key described above — issued on your LAN, kept
  in the Keychain at both ends, never sent anywhere else. The relay
  forwards ciphertext. A notification service extension on the phone opens it.
- **No key identifier travels.** The obvious design says which key sealed a
  push so the phone knows which to try; here that would mean a host name in the
  clear, and a host name in this app is "Renyi's MacBook Air". The phone tries
  the keys it has instead.
- **Nothing is stored.** The relay has no database and no device registry.
  Tokens live on the paired Mac, are handed over one at a time and forgotten.

What it can genuinely see: the APNs device token, which is unavoidable because
that is the address; the size and timing of pushes, which is a side channel
saying roughly when you are working; the notification *category* — one bit
distinguishing "an agent is asking permission" from "an agent reported
something" — which is in the clear because a category supplied only by the
extension can be resolved too late for the Approve and Deny buttons; the
interruption level and relevance score, which say how loudly to ask; the
approval's deadline, as the push's expiry; and a collapse id, which is a
hash of the alert's id — the same construction as the thread id, so two
pushes about one target replace rather than stack, and neither says which
target. The relay and Apple never see a target name, an agent's words, or a
command.

What somebody who obtains a device token can do: send that phone a push it
cannot decrypt, which shows "Nimlet · Something needs you" — and nothing
else, because of two checks. The relay forwards only a push shaped exactly as
the Mac writes one: the fixed placeholder text, one of the two categories, a
hashed thread id, and a sealed box; a payload carrying its own words or its
own buttons is refused with a 400. And the phone's notification extension
shows the placeholder, with no buttons and no identifiers, for any push whose
box it cannot open, rather than whatever the payload said. The bearer secret
the Mac carries is therefore not a way to write notifications. Someone with a
token can still make a phone buzz; they cannot read anything, and they cannot
cause an approval. The Approve button opens the app and the decision travels
over the real connection; a push can never carry one.

There is no relay address compiled into a plain checkout. A build made with
`MICE_PUSH_RELAY_URL` set carries one, and says so in Settings; otherwise,
until `mice.push.relay` is set, none of this path exists. See `Relay/README.md`.

## What is not shipped

**The code listener has no per-device keys.** Every client of it derives the
same pre-shared key from the same code: rotating the code invalidates all of
them at once. Only the `nimlet` tool on this Mac uses it.

**Not everything is in the Keychain.** Both ends' trust keys, the push keys
and the push relay's bearer secret are, but the pairing code is still in the host's preferences as
`mice.pairingCode.v1`, and the approved-device list sits beside it as
`mice.devices.approved.v1`. Any process running as you can read both —
`defaults read com.renyicao.mice.host mice.pairingCode.v1` is the whole exploit.
The `nimlet` command-line tool keeps a second copy in `~/.config/nimlet/config.json`
— that one at least is mode 0600. Local malware already running as the user is
therefore outside what Nimlet defends against, and would be even if the key were
per-device.

**The code is meant to be read off a screen.** It is displayed in the menu bar
popover so it can be typed into a phone. A screenshot, a glance over a shoulder
or a screen share during a call all get it far more cheaply than guessing does.
Rotate it afterwards.

**The throttle is keyed by peer address.** An attacker who can present many
source addresses on the same link gets the first two free attempts back for each
one. It raises the cost of a spray; it does not bound it.

**Reachability is wider than "my Wi-Fi".** The trust and code listeners enable
peer-to-peer, so a phone can reach the Mac over AWDL without being on the same
Wi-Fi network. Any device within radio range is a potential client, subject to
everything above. The away listener does not enable peer-to-peer: a socket that
arrives over the internet has no business being offered a radio link.

**The connect relay is optional, and sees only ciphertext.** If your Mac's
internet connection is behind a carrier-grade NAT, or the router will not
forward a port, nothing can dial the Mac directly. Setting `mice.relay` and
`mice.relayFingerprint` makes the Mac keep an outbound connection to a relay
you run (`Relay/connect/`). A phone paired by key then dials the relay, which
routes on the TLS ALPN hint (or legacy server name) and splices the two sockets. The TLS 1.3 session
inside is end to end: the phone pins the Mac's key, the Mac pins the phone's,
and the relay holds neither, so it cannot read the traffic now or later.

**The Mac pins the relay too.** Its own connections to the relay — the control
line and each phone's byte stream — are TLS 1.3 to the relay's P-256 key,
which the relay prints when it starts and the user puts in
`mice.relayFingerprint`. Without that, anybody on the path between Mac and
relay could answer as the relay: open bridges into the away listener at will,
or stand in the middle of the registration and hold this Mac's route at the
real relay. With it, a relay presenting any other key is refused before a
line is exchanged, and a challenge signed for one relay is of no use at
another.

What the relay can see: the Mac's public key, which is how the Mac registers;
each phone's source address; and the size and timing of the traffic. What it can
do: refuse to carry traffic, or connect a phone to the wrong Mac. The wrong Mac
fails the phone's pin. Traffic arriving through the relay enters the Mac's away
listener, which accepts only keys the user has paired and never pairs a new one.
No relay address is compiled in. Without `mice.relay` none of this exists, and
away access behind a carrier-grade NAT is reported as unavailable rather than
retried forever.

**What somebody who knows a route can do, and what bounds it.** A route is
derived from the Mac's public key, which anybody who can start a handshake on
the trust port, or who saw a pairing QR code, has. Knowing it buys a splice
to the Mac's away listener and nothing past the handshake, which their key
fails. What it used to buy as well was a seat: a stranger could hold the
relay's pending slots for that route, and the Mac's connection slots behind
them, with ClientHellos the Mac was about to refuse. Now the relay tells the
Mac each phone's address, so the away listener's handshake throttle counts
the failure against that phone rather than against the loopback the relay's
pump arrives from; the relay itself holds off a source whose splices keep
dying within three seconds without the owning Mac confirming an approved
phone key (free twice, then two seconds doubling to five
minutes); a bridge the relay opens and never fills is dropped after five
seconds; and sockets that arrived from away have a budget of their own on
the Mac, so filling it costs the phone at the desk nothing. Per-source limits
at the relay are keyed on the IPv4 address or the IPv6 /64, so a /64 cannot
be rotated through to escape them, and the relay caps its own open sockets.

## In scope

Anything that gets keystrokes or pointer events into a Mac without the user
having approved that device: handshake bypasses, flaws in the framing or
decoding that run before approval is checked, approval checks that can be
skipped for some message, a way to make the Mac approve a device the user did
not choose, or a way to read the pairing code off a machine you do not already
control.

For pairing by key: completing the trust or away handshake with a key the user
has not paired, redeeming an invitation without the QR secret, redeeming one
twice or after it expired, sending anything but `pair` on an unpaired key, and
anything that makes the device id on a trust socket differ from the key it
proved.

For away access specifically: anything that gets a push key issued to a device
the user has not paired, anything that lets a revoked device still complete
the away handshake, a way to obtain a key over the away path itself, and
anything reachable on the away port before the handshake completes.

## Out of scope

Anything that starts from code already running as the user on the Mac, since
that can read the pairing code from preferences and, for that matter, post its
own CGEvents without Nimlet. Physical access to an unlocked Mac. Someone typing
the code in because they were shown it. The absence of per-device keys on the code
listener, which is documented above rather than unknown.
