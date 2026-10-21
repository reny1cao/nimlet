# The connect relay

This relay is how a phone on cellular reaches a Mac that cannot be dialled: one
behind a carrier-grade NAT, a router that won't forward a port, or a network
that drops all inbound traffic. It is one dependency-free Node program,
`relay.mjs`.

It is also, since 2026-10-05, mostly a **way to get started**. A session still
comes up through the relay, but right behind `hello` the phone offers the Mac
an IPv6 address and port inside that session, both ends punch UDP towards
each other, and the session moves onto a KCP tunnel over the punched path
(`Shared/DirectPath.swift`, `DirectLink/DirectTunnel.swift`). Measured on 5G
from Shanghai: the relay's round trip was 924 ms with ~24% loss on the phone's
uplink to Singapore; the direct path's is 77 ms with none. The relay carries a
whole session only when no direct path can be punched — no IPv6, or a firewall
that will not pass the replies.

## What it can and cannot see

It splices TCP connections and nothing more. The phone's TLS 1.3 handshake
passes through it to the Mac, and each end pins the other's key, so the traffic
here is ciphertext with forward secrecy. The relay never holds a key that could
decrypt it.

The Mac's own connections to the relay are TLS as well — not to hide what
they carry, which is the phone's ciphertext and a few lines of control, but so
the Mac knows it is talking to *this* relay. The relay has a P-256 key of its
own; the Mac pins it (`mice.relayFingerprint`) and refuses any other before a
line is exchanged. Without that, anyone between the Mac and the relay could
answer as the relay.

- **Routing.** It reads ALPN `nimlet-<route>` in the phone's ClientHello.
  The route is the first 20 bytes of SHA-256 of the Mac's public key, in hex.
  Older phones can still use SNI `<route>.nimlet`. ALPN avoids a synthetic
  DNS name that an iOS VPN proxy may try to resolve before connecting.
- **Registration.** A Mac registers by signing a challenge with its key, so it
  can register only the route that key implies.
- **Visible to the relay:** each Mac's public key, the phones' addresses, and
  the size and timing of the traffic. Each phone's address is also told to
  its Mac, so the Mac's away listener can count a failed handshake against
  that phone rather than against the relay.
- **Holding off abuse.** A source whose splices keep dying within three
  seconds without its Mac confirming an approved TLS key is held off: free
  twice, then two seconds doubling to five minutes. Per-source limits are
  keyed on the IPv4 address or the IPv6 /64. A spliced pair with no bytes
  either way for ten minutes is dropped, and the relay caps its own open
  sockets. The Mac sends `VERIFIED <id>` on its pinned control connection
  after the away listener authenticates a paired phone. Only the Mac that
  owns that route can confirm its splice. A short grace window accepts a
  confirmation arriving after the data socket closes. A phone cancelling a
  losing race does not count as rejection. Retained splice
  metadata is capped at 64 per route. Quick successful sessions are not failures.
- **Not visible:** anything inside the TLS session. If the relay connects a
  phone to the wrong Mac, the phone's pinned key rejects it.

On the Mac, traffic from the relay enters the away listener. That listener
accepts only keys the user has paired, and it never pairs new ones.

## Running it

It needs Node 20 or newer on any host the Mac and the phone can both reach. A
small VPS works fine.

```bash
node Relay/connect/relay.mjs --port 7443 --key /var/lib/nimlet/relay-key.pem
```

The key file is made on the first run, mode 0600, and kept: the Macs pin
the key, so a relay that made a new one on every start would be a relay no
Mac could talk to twice. On every start it prints one line —

```
listening 7443 <fingerprint>
```

— and the fingerprint is what goes into each Mac's `mice.relayFingerprint`.
Keep the file where only the relay's user can read it; whoever holds it can
be this relay to every Mac that pinned it.

As a systemd service:

```ini
[Unit]
Description=Nimlet connect relay
After=network-online.target

[Service]
ExecStart=/usr/bin/node /opt/nimlet/relay.mjs --port 7443 --key /var/lib/nimlet/relay-key.pem
Restart=always
DynamicUser=yes
StateDirectory=nimlet
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

Open TCP 7443 in the host's firewall.

## Pointing the Mac at it

```bash
defaults write com.renyicao.mice.host mice.relay relay.example.com:7443
defaults write com.renyicao.mice.host mice.relayFingerprint <the fingerprint the relay printed>
```

Then relaunch Nimlet. The relay stays registered while all four of these hold:

- **Reachable on cellular** is on;
- both settings above are present — without the fingerprint the menu says
  so and nothing is dialled;
- at least one phone is paired by key (**Pair a Phone…** in the menu).

If the relay's key ever changes, the menu's relay line says the key is not
the one in `mice.relayFingerprint`, and the setting has to be updated by hand.
That is the point: a relay whose key changed is a relay somebody may have
replaced.

The menu's away section shows the relay's state. Connected phones are told about
the relay on their next connection. On cellular alone a phone dials the relay
first, because it is the one way in that does not depend on the Mac's router,
and races its direct addresses behind it; on any other network the relay comes
last. Once a session is up on the relay the phone keeps looking for a direct
or local route and moves the session onto it when one answers and is quicker
(`RoutePolicy`), so the relay carries a session only for as long as nothing
better exists.

## Spares

A phone's socket arriving at the relay used to wait for the Mac to be told
(`OPEN`), dial the relay, and finish a TLS handshake with it — about three
round trips between the Mac and the relay, paid by every socket a phone opens
(control, mirror, sound, each upload). From Shanghai to this relay in
Singapore that was measured at 670 ms median for the dial and handshake alone
(2026-10-05), and `bench-spares.mjs` puts the whole difference at about a
second per socket.

So a Mac that ends its `NIMLET-HOST` line with ` spares` is answered
`OK <route> <token>` and keeps two connections parked in advance
(`NIMLET-SPARE 1 <route> <token>`). A phone arriving while one is parked is
told to it (`PHONE <id> <address>`, then the ClientHello) and spliced at once;
with none parked the relay falls back to `OPEN`. The token is fresh on every
registration and only ever travels inside the Mac's TLS to the relay, so
nobody else can park a socket on a route. Nothing about the end-to-end TLS
changes: a spare carries the phone's ciphertext exactly as a `NIMLET-DATA`
connection does.

```bash
node Relay/connect/bench-spares.mjs 330 150   # Mac↔relay RTT, phone↔relay RTT, ms
```

## Deploying a new version

Both directions are compatible, so the relay and the Macs can be updated in
either order:

- an older Mac never says ` spares` and is answered `OK <route>` exactly as
  before;
- a newer Mac talking to an older relay gets no token and never opens a spare.

To deploy (not done from this repository):

1. `node --test Relay/connect/relay.test.mjs` on the build being shipped.
2. Copy the old `/opt/nimlet-relay/relay.mjs` aside as `relay.mjs.prev`.
3. Copy the new file in its place and `systemctl restart nimlet-relay`. The
   key file is unchanged, so no Mac has to be told anything; registered Macs
   reconnect by themselves within their retry backoff (one to thirty seconds).
4. `journalctl -u nimlet-relay -f`: a registered Mac shows `host: … registered`,
   and the first phone after it `phone: spliced to a spare`.

To roll back: copy `relay.mjs.prev` back and restart. Macs fall back to `OPEN`
on their next registration without any change on their side.

## Cost

Mirror video through the relay is capped at 2.5 Mbps, which is about 1.1 GB per
hour while the mirror is open. Pointer, keyboard and text traffic is negligible.
Audio adds 96 kbps while listening.

## Tests

```bash
make relay-test
```

That runs the relay's own tests in Node, including the spares. The end-to-end tests are
`Tests/NimletTests/RelayLinkTests.swift` (Network.framework at both ends, through
the real relay, run by `make test`) and
`testAPhonePairedByKeyReachesTheMacThroughARelay` in `NimletConnectionTests` (the
real iOS client, through a stand-in relay).
