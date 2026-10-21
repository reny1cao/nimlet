/**
 * The connect relay: how a phone on cellular reaches a Mac that cannot be
 * dialled — behind a carrier-grade NAT, a router that will not forward a port,
 * a network that drops everything inbound.
 *
 * It splices TCP and nothing else. The phone's TLS 1.3 handshake goes straight
 * through it to the Mac, both ends pin each other's key, and what passes here
 * is ciphertext with forward secrecy: this program never holds a key that could
 * read it, now or later. See docs/architecture/trust-layer.md.
 *
 * One port, two kinds of caller, both of which open with a TLS ClientHello and
 * are told apart by the routing hint in it:
 *
 * - A **phone** sends ALPN `nimlet-<route>` (older phones name `<route>.nimlet`).
 *   Its TLS is end to end with the Mac and is spliced through untouched;
 *   the routing hint is all this reads of it.
 * - A **Mac** sends no phone routing hint. Its TLS terminates *here*: the
 *   relay presents its own P-256 key, which the Mac pins (`mice.relayFingerprint`),
 *   so nobody on the path between them can answer as the relay. Inside that
 *   TLS it speaks lines. It holds one control connection open:
 *     → NIMLET-HOST 1 <public key, x9.63, base64url>
 *     ← CHALLENGE <nonce>
 *     → PROOF <ECDSA-SHA256 signature over "nimlet-relay-v1:" + nonce, DER, base64url>
 *     ← OK <route>
 *   where <route> is the first 20 bytes of SHA-256 of that key, in hex — so a
 *   Mac can only ever register as the key it holds. Then, for each phone:
 *     ← OPEN <id> <phone address>
 *   and the Mac opens a fresh (TLS) connection that says `NIMLET-DATA 1 <id>`
 *   and is from then on the phone's byte stream.
 *
 *   **Spares.** That fresh connection is a TCP and a TLS handshake between
 *   the Mac and here, after the phone has already arrived — measured from
 *   Shanghai to this server in Singapore on 2026-10-05, 670 ms median, paid
 *   again by every socket a phone opens (control, picture, sound). So a Mac
 *   that ends its hello with ` spares` is given a token with its OK,
 *     ← OK <route> <token>
 *   and keeps a couple of connections open in advance, each saying
 *     → NIMLET-SPARE 1 <route> <token>
 *   When a phone arrives and a spare is waiting, the relay tells it
 *     ← PHONE <id> <phone address>
 *   on that spare, sends the ClientHello straight after, and splices: no
 *   OPEN, no handshake while the phone waits. Without a spare it falls back to
 *   OPEN. The token only ever travels inside the Mac's own TLS and is new on
 *   every registration, so nobody else can park a socket on a route.
 *
 *   node Relay/connect/relay.mjs --port 7443 --key /var/lib/nimlet/relay-key.pem
 *
 * The key file is made on first run (mode 0600). The relay prints its
 * fingerprint on every start; that is what goes into `mice.relayFingerprint`.
 */
import net from 'node:net'
import dgram from 'node:dgram'
import tls from 'node:tls'
import fs from 'node:fs'
import crypto from 'node:crypto'
import { Duplex } from 'node:stream'
import { pathToFileURL } from 'node:url'

export const SNI_SUFFIX = '.nimlet'
const CHALLENGE_PREFIX = 'nimlet-relay-v1:'
export const LIMITS = {
  helloBytes: 16 * 1024,     // a ClientHello, or a Mac's first line
  pendingMs: 10_000,         // how long a phone waits for its Mac to answer OPEN
  handshakeMs: 10_000,       // how long anyone has to say who they are
  pingMs: 20_000,            // keeps the Mac's NAT mapping alive, and finds dead Macs
  idleMs: 10 * 60_000,       // a spliced pair with no bytes either way for this long is dropped
  phonesPerAddress: 16,      // concurrent phone sockets from one source
  hostsPerAddress: 4,        // registered Macs from one source
  unidentifiedPerAddress: 32, // sockets from one source that have not yet said what they are
  unidentifiedTotal: 1_000,  // and from everyone put together
  pendingPerRoute: 8,
  sparesPerRoute: 4,         // connections a Mac keeps ready for the next phone
  datagramPairsPerRoute: 4,  // UDP relay sessions a Mac may hold open at once
  datagramIdleMs: 120_000,   // a UDP pair nobody has used for this long is forgotten
  datagramBytesPerSecond: 2_500_000, // per pair, both directions together (20 Mbit/s)
  routes: 10_000,
  connections: 5_000,        // the server's own cap on open sockets
  // A phone whose splices keep dying young without its Mac confirming an
  // approved key — what a stranger who learned a route produces — is held off,
  // the way the Mac holds off a bad pairing code: free twice, then 2 s,
  // doubling to five minutes, forgotten after an hour without a failure.
  shortSpliceMs: 3_000,
  failuresBeforeBackoff: 3,
  recentSplicesPerRoute: 64, // bounded metadata while control confirms a quick handshake
  maxBackoffMs: 300_000,
  forgetFailuresMs: 3_600_000,
}

/** The route a key registers under: 40 hex characters, a valid DNS label. */
export function routeFor(publicKeyX963) {
  return crypto.createHash('sha256').update(publicKeyX963).digest('hex').slice(0, 40)
}

export const base64url = (bytes) => Buffer.from(bytes).toString('base64url')
const fromBase64url = (text) => Buffer.from(text, 'base64url')

/**
 * Who a source address is, for every per-source limit here.
 *
 * IPv4 is the address itself: a carrier's NAT puts thousands of phones behind
 * one, and widening it would let one of them cost the rest their relay. IPv6
 * is the /64, because a /64 is one subscriber and a subscriber has 2^64
 * addresses to rotate through — keyed on the full address, every per-source
 * cap would be no cap at all.
 */
export function sourceKey(address) {
  if (!address) return '?'
  const bare = address.startsWith('::ffff:') && address.includes('.') ? address.slice(7) : address
  if (!bare.includes(':')) return bare
  try {
    const hex = Buffer.from(ipv6Bytes(bare)).subarray(0, 8).toString('hex')
    return hex.match(/.{4}/g).join(':') + '::/64'
  } catch {
    return bare
  }
}

function ipv6Bytes(text) {
  const [head, tail = ''] = text.split('::')
  const parse = (part) => part === '' ? [] : part.split(':').map((h) => parseInt(h, 16))
  const a = parse(head)
  const b = parse(tail)
  if (text.includes('::') ? a.length + b.length > 7 : a.length !== 8) throw new RangeError('not IPv6')
  const words = [...a, ...new Array(8 - a.length - b.length).fill(0), ...b]
  if (words.some((w) => !(w >= 0 && w <= 0xffff))) throw new RangeError('not IPv6')
  const bytes = []
  for (const w of words) bytes.push(w >> 8, w & 0xff)
  return bytes
}

/**
 * The server name in a TLS ClientHello, or `undefined` if the buffer does not
 * hold a whole one yet, or `null` if it never will (not TLS, no SNI, malformed).
 */
function helloExtensions(buffer) {
  if (buffer.length < 5) return undefined
  if (buffer[0] !== 0x16 || buffer[1] !== 0x03) return null
  const recordLength = buffer.readUInt16BE(3)
  if (recordLength > LIMITS.helloBytes) return null
  if (buffer.length < 5 + recordLength) return undefined
  let at = 5
  const end = 5 + recordLength
  const need = (n) => { if (at + n > end) throw new RangeError('short') }
  try {
    need(4)
    if (buffer[at] !== 0x01 || buffer.readUIntBE(at + 1, 3) + 4 !== recordLength) return null
    at += 4
    need(34); at += 34
    need(1); const sessionLength = buffer[at++]; need(sessionLength); at += sessionLength
    need(2); const cipherLength = buffer.readUInt16BE(at); at += 2; need(cipherLength); at += cipherLength
    need(1); const compressionLength = buffer[at++]; need(compressionLength); at += compressionLength
    need(2)
    const extensionsEnd = at + 2 + buffer.readUInt16BE(at)
    at += 2
    if (extensionsEnd !== end) return null
    const extensions = new Map()
    while (at < extensionsEnd) {
      need(4)
      const type = buffer.readUInt16BE(at)
      const length = buffer.readUInt16BE(at + 2)
      at += 4; need(length)
      if (extensions.has(type)) return null
      extensions.set(type, buffer.subarray(at, at + length))
      at += length
    }
    return extensions
  } catch { return null }
}

function nameFromExtensions(extensions) {
  const name = extensions.get(0)
  if (!name || name.length < 5 || name.readUInt16BE(0) !== name.length - 2 || name[2] !== 0
      || name.readUInt16BE(3) !== name.length - 5) return null
  return name.subarray(5).toString('ascii').toLowerCase()
}

export function serverName(buffer) {
  const extensions = helloExtensions(buffer)
  return extensions == null ? extensions : nameFromExtensions(extensions)
}

/** Prefer ALPN routing; retain SNI routing for phones released before it. */
export function clientRoute(buffer) {
  const extensions = helloExtensions(buffer)
  if (extensions == null) return extensions
  const asked = nameFromExtensions(extensions)
  const legacy = asked?.endsWith(SNI_SUFFIX) ? asked.slice(0, -SNI_SUFFIX.length) : null
  const sniRoute = legacy && /^[0-9a-f]{40}$/.test(legacy) ? legacy : null
  const protocols = extensions.get(16)
  const routes = new Set()
  if (protocols) {
    if (protocols.length < 2 || protocols.readUInt16BE(0) !== protocols.length - 2) return null
    let at = 2
    while (at < protocols.length) {
      const length = protocols[at++]
      if (!length || at + length > protocols.length) return null
      const protocol = protocols.subarray(at, at + length).toString('ascii')
      const match = /^nimlet-([0-9a-f]{40})$/.exec(protocol)
      if (match) routes.add(match[1])
      at += length
    }
  }
  if (routes.size > 1) return null
  const alpnRoute = routes.values().next().value
  if (alpnRoute && sniRoute && alpnRoute !== sniRoute) return null
  return alpnRoute ?? sniRoute
}

/** Whether a server name is a phone asking for a route. */
export function routeIn(name) {
  const asked = name && name.endsWith(SNI_SUFFIX) ? name.slice(0, -SNI_SUFFIX.length) : null
  // Only ever a route the relay could hold: forty hex characters. Anything
  // else is not logged as written, so a server name cannot forge a log line.
  return asked && /^[0-9a-f]{40}$/.test(asked) ? asked : null
}

// MARK: - The relay's own key

/**
 * The relay's identity: a P-256 key, a self-signed certificate around it for
 * TLS to carry, and the fingerprint the Mac pins — SHA-256 of the key's
 * uncompressed point, base64url, exactly as `TrustFingerprint` spells it.
 *
 * The certificate is built by hand because Node has no API to make one, and
 * nothing reads its names or dates: the Mac's verify block looks at the key
 * and nothing else. It is the same forty lines of DER `SelfSignedCertificate`
 * writes in Swift.
 */
export function relayIdentity(privateKey = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey) {
  const jwk = crypto.createPublicKey(privateKey).export({ format: 'jwk' })
  const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')])
  const der = selfSignedCertificate(privateKey, point)
  const cert = `-----BEGIN CERTIFICATE-----\n${der.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`
  return {
    key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    cert,
    fingerprint: crypto.createHash('sha256').update(point).digest('base64url'),
  }
}

/** The key at `path`, made and written (owner-only) if there is none. */
export function loadOrCreateKey(path) {
  try {
    return crypto.createPrivateKey(fs.readFileSync(path))
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
    const key = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey
    fs.writeFileSync(path, key.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 })
    return key
  }
}

const DER = {
  tlv(tag, value) {
    const length = value.length
    let header
    if (length < 0x80) header = Buffer.from([tag, length])
    else {
      const bytes = []
      let remaining = length
      while (remaining > 0) { bytes.unshift(remaining & 0xff); remaining >>= 8 }
      header = Buffer.from([tag, 0x80 | bytes.length, ...bytes])
    }
    return Buffer.concat([header, value])
  },
  sequence(...parts) { return DER.tlv(0x30, Buffer.concat(parts)) },
  set(...parts) { return DER.tlv(0x31, Buffer.concat(parts)) },
  explicit(tag, value) { return DER.tlv(0xA0 | tag, value) },
  utf8(text) { return DER.tlv(0x0C, Buffer.from(text, 'utf8')) },
  bitString(bytes) { return DER.tlv(0x03, Buffer.concat([Buffer.from([0]), bytes])) },
  integer(bytes) {
    let body = Buffer.from(bytes)
    while (body.length > 1 && body[0] === 0) body = body.subarray(1)
    if (body[0] & 0x80) body = Buffer.concat([Buffer.from([0]), body])
    return DER.tlv(0x02, body)
  },
  utcTime(date) {
    const text = date.toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'
    return DER.tlv(0x17, Buffer.from(text, 'ascii'))
  },
  oidECDSAWithSHA256: Buffer.from([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]),
  oidECPublicKey: Buffer.from([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
  oidP256: Buffer.from([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]),
  oidCommonName: Buffer.from([0x06, 0x03, 0x55, 0x04, 0x03]),
}

function selfSignedCertificate(privateKey, point, now = new Date()) {
  const name = DER.sequence(DER.set(DER.sequence(DER.oidCommonName, DER.utf8('Nimlet relay'))))
  const validity = DER.sequence(DER.utcTime(new Date(now.getTime() - 86_400_000)),
                                DER.utcTime(new Date(Date.UTC(2049, 11, 31, 23, 59, 59))))
  const publicKeyInfo = DER.sequence(DER.sequence(DER.oidECPublicKey, DER.oidP256), DER.bitString(point))
  const serial = crypto.randomBytes(16)
  serial[0] = (serial[0] & 0x7f) | 0x01
  const tbs = DER.sequence(
    DER.explicit(0, DER.integer([2])),
    DER.integer(serial),
    DER.sequence(DER.oidECDSAWithSHA256),
    name,
    validity,
    name,
    publicKeyInfo,
  )
  const signature = crypto.sign('sha256', tbs, { key: privateKey, dsaEncoding: 'der' })
  return DER.sequence(tbs, DER.sequence(DER.oidECDSAWithSHA256), DER.bitString(signature))
}

// MARK: - Line reading

/** Reads one `\n`-terminated line off a socket that may then carry anything. */
function firstLine(socket, buffered, onLine) {
  // Chunks kept as they came and joined once, when the line is complete:
  // concatenating on every chunk is quadratic in a trickled-in line.
  const chunks = buffered.length ? [buffered] : []
  let length = buffered.length
  const finish = () => {
    socket.off('data', more)
    // Paused before handing over: with no 'data' listener a flowing socket
    // drops what arrives, and whoever takes it next decides when to read.
    socket.pause()
    const data = Buffer.concat(chunks, length)
    const newline = data.indexOf(0x0a)
    onLine(data.subarray(0, newline).toString('utf8').trim(), data.subarray(newline + 1))
  }
  const more = (chunk) => {
    chunks.push(chunk)
    length += chunk.length
    if (chunk.indexOf(0x0a) >= 0) return finish()
    if (length > LIMITS.helloBytes) socket.destroy()
  }
  if (buffered.indexOf(0x0a) >= 0) return finish()
  socket.on('data', more)
}

/**
 * Terminates TLS on a socket whose ClientHello has already been read off it.
 *
 * `tls.TLSSocket` over a real `net.Socket` takes the socket's handle and never
 * sees what its JavaScript side had already buffered, so the bytes already
 * read would be lost. Over a plain Duplex it reads what the Duplex gives it —
 * the ClientHello first, then everything the socket delivers from then on.
 */
function terminate(socket, buffered, identity) {
  const carrier = new Duplex({
    read() { socket.resume() },
    write(chunk, _encoding, callback) { socket.write(chunk, callback) },
    final(callback) { socket.end(callback) },
  })
  carrier.push(buffered)
  socket.on('data', (chunk) => { if (!carrier.push(chunk)) socket.pause() })
  socket.on('end', () => carrier.push(null))
  socket.on('close', () => carrier.destroy())
  carrier.on('close', () => socket.destroy())
  carrier.on('error', () => {})
  const secure = new tls.TLSSocket(carrier, { isServer: true, key: identity.key, cert: identity.cert, minVersion: 'TLSv1.3' })
  secure.on('error', () => socket.destroy())
  return secure
}

export function createRelay({ log = () => {}, identity = relayIdentity() } = {}) {
  /** route → { socket, pending: Map<id, phone> } */
  const routes = new Map()
  /** id → { phone, entry }, for the Mac's data connection to find in one step. */
  const pendingByID = new Map()
  const phonesByAddress = new Map()
  const hostsByAddress = new Map()
  const unidentifiedByAddress = new Map()
  /** sourceKey → { failures, last, until } */
  const backoff = new Map()
  let unidentified = 0

  function count(map, address, delta) {
    const next = (map.get(address) ?? 0) + delta
    if (next <= 0) map.delete(address); else map.set(address, next)
    return next
  }
  const countPhone = (address, delta) => count(phonesByAddress, address, delta)

  function noteShortSplice(source) {
    const now = Date.now()
    for (const [key, entry] of backoff) if (now - entry.last > LIMITS.forgetFailuresMs) backoff.delete(key)
    const entry = backoff.get(source) ?? { failures: 0, last: 0, until: 0 }
    entry.failures += 1
    entry.last = now
    if (entry.failures >= LIMITS.failuresBeforeBackoff) {
      entry.until = now + Math.min(2 ** (entry.failures - LIMITS.failuresBeforeBackoff + 1) * 1000, LIMITS.maxBackoffMs)
      log(`phone: ${entry.failures} short splices from one source, held off ${Math.round((entry.until - now) / 1000)}s`)
    }
    backoff.set(source, entry)
  }
  const heldOff = (source) => (backoff.get(source)?.until ?? 0) > Date.now()

  function host(socket, raw, address, line, rest) {
    const [, version, key, ...features] = line.split(' ')
    if (version !== '1' || !key) return socket.destroy()
    let publicKey
    const x963 = fromBase64url(key)
    // Exactly an uncompressed P-256 point. Anything longer would hash to a
    // fresh route for the same key, and one key is one route.
    if (x963.length !== 65 || x963[0] !== 0x04) return socket.destroy()
    try {
      publicKey = crypto.createPublicKey({
        key: { kty: 'EC', crv: 'P-256', x: base64url(x963.subarray(1, 33)), y: base64url(x963.subarray(33, 65)) },
        format: 'jwk',
      })
    } catch { return socket.destroy() }
    const nonce = crypto.randomBytes(32)
    socket.write(`CHALLENGE ${base64url(nonce)}\n`)
    // `firstLine` attaches its listener to a socket the previous one paused.
    queueMicrotask(() => socket.resume())
    firstLine(socket, rest, (proofLine, after) => {
      const [word, signature] = proofLine.split(' ')
      const ok = word === 'PROOF' && signature && crypto.verify(
        'sha256', Buffer.concat([Buffer.from(CHALLENGE_PREFIX), nonce]), publicKey, fromBase64url(signature))
      if (!ok) { log('host: bad proof'); return socket.destroy() }
      socket.removeAllListeners('data')
      const route = routeFor(x963)
      if (!routes.has(route) && routes.size >= LIMITS.routes) return socket.destroy()
      if (!routes.has(route) && count(hostsByAddress, address, 1) > LIMITS.hostsPerAddress) {
        count(hostsByAddress, address, -1)
        return socket.destroy()
      }
      if (routes.has(route)) count(hostsByAddress, address, 1)
      // A Mac that reconnects replaces itself; the old socket is a dead one
      // its NAT has not told anybody about yet.
      routes.get(route)?.socket.destroy()
      const wantsSpares = features.includes('spares')
      const entry = {
        socket, pending: new Map(), splices: new Map(), spares: [],
        spareToken: wantsSpares ? base64url(crypto.randomBytes(24)) : null,
      }
      routes.set(route, entry)
      clearTimeout(raw.handshakeTimer)
      // The PING below finds a dead Mac; TCP keepalive is only the backstop.
      raw.setKeepAlive(true, LIMITS.pingMs * 3)
      socket.write(entry.spareToken ? `OK ${route} ${entry.spareToken}\n` : `OK ${route}\n`)
      log(`host: ${route} registered`)
      let lastPong = Date.now()
      const ping = setInterval(() => {
        if (Date.now() - lastPong > LIMITS.pingMs * 2.5) return socket.destroy()
        socket.write('PING\n')
      }, LIMITS.pingMs)
      let lines = after.toString('utf8')
      socket.on('data', (chunk) => {
        lines += chunk.toString('utf8')
        let newline
        while ((newline = lines.indexOf('\n')) >= 0) {
          const line = lines.slice(0, newline).trim()
          if (line === 'PONG') lastPong = Date.now()
          else if (line.startsWith('UDP ')) openDatagramPair(entry, route, line.slice(4).trim())
          else if (line.startsWith('VERIFIED ')) {
            // Only the Mac that owns this route may attest its own splice.
            const id = line.slice('VERIFIED '.length)
            const phone = entry.pending.get(id) ?? entry.splices.get(id)
            if (phone) phone.authenticated = true
          }
          lines = lines.slice(newline + 1)
        }
        if (lines.length > LIMITS.helloBytes) socket.destroy()
      })
      socket.resume()
      socket.on('close', () => {
        clearInterval(ping)
        for (const token of entry.datagramTokens ?? []) datagramPairs.delete(token)
        count(hostsByAddress, address, -1)
        if (routes.get(route) === entry) routes.delete(route)
        for (const [id, phone] of entry.pending) { pendingByID.delete(id); phone.destroy() }
        for (const spare of entry.spares) spare.destroy()
        entry.spares = []
        // A registered Mac going away is not a failed phone authentication.
        for (const phone of entry.splices.values()) {
          phone.authenticated = true
          phone.destroy()
        }
        entry.splices.clear()
        log(`host: ${route} gone`)
      })
    })
  }

  function data(socket, raw, line, rest) {
    const [, version, id] = line.split(' ')
    if (version !== '1' || !id) return socket.destroy()
    const waiting = pendingByID.get(id)
    if (waiting) {
      const { phone, entry } = waiting
      pendingByID.delete(id)
      entry.pending.delete(id)
      clearTimeout(phone.pendingTimer)
      clearTimeout(raw.handshakeTimer)
      // The ClientHello this read, then everything after it, in order.
      socket.write(phone.hello)
      phone.hello = null
      if (rest.length) phone.write(rest)
      splice(phone, socket, raw, entry, id)
      log('phone: spliced')
      return
    }
    socket.destroy()
  }

  /** A connection a registered Mac opened before any phone needed it. */
  function spare(socket, raw, line) {
    const [, version, route, token] = line.split(' ')
    const entry = version === '1' ? routes.get(route) : undefined
    const expected = entry?.spareToken ? Buffer.from(entry.spareToken) : null
    const given = Buffer.from(token ?? '')
    if (!expected || given.length !== expected.length || !crypto.timingSafeEqual(given, expected)
        || entry.spares.length >= LIMITS.sparesPerRoute) {
      // The TCP socket too: the TLS one over it does not take it down.
      socket.destroy(); raw.destroy()
      return
    }
    clearTimeout(raw.handshakeTimer)
    // Waiting is all it does until a phone comes. Its own keepalive and the
    // Mac's replacing it are what notice a dead one; the idle limit below is
    // the backstop.
    raw.setTimeout(LIMITS.idleMs, () => socket.destroy())
    entry.spares.push(socket)
    socket.once('close', () => { entry.spares = entry.spares.filter((s) => s !== socket) })
  }

  /** Two sockets, joined: whatever one reads the other writes. */
  function splice(phone, socket, raw, entry, id) {
    phone.pipe(socket)
    socket.pipe(phone)
    const opened = Date.now()
    entry.splices.set(id, phone)
    let judged = false
    const close = (closedByMac = false) => {
      // Both sockets report the close; the splice is judged once. A phone
      // cancelling a losing race is not a Mac rejecting its key.
      if (!judged) {
        judged = true
        if (closedByMac && Date.now() - opened < LIMITS.shortSpliceMs) {
          // The control socket can deliver VERIFIED after the data socket
          // closes. Keep a bounded grace window for that acknowledgement.
          setTimeout(() => {
            if (!phone.authenticated) noteShortSplice(phone.sourceKey)
            entry.splices.delete(id)
          }, Math.max(0, opened + LIMITS.shortSpliceMs - Date.now())).unref()
        } else entry.splices.delete(id)
      }
      phone.destroy(); socket.destroy()
    }
    phone.once('close', () => close(false))
    socket.once('close', () => close(true))
    // Neither side has sent a byte in ten minutes: a mirror sends sixty
    // frames a second and the control socket pings every twelve seconds,
    // so this is a pair whose ends have both gone away without saying so.
    phone.setTimeout(LIMITS.idleMs, close)
    raw.setTimeout(LIMITS.idleMs, close)
  }

  function phone(socket, hello, route) {
    const entry = routes.get(route)
    log(`phone: ${route} ${entry ? 'open' : 'refused'}`)
    if (!entry || entry.pending.size >= LIMITS.pendingPerRoute
        || entry.splices.size >= LIMITS.recentSplicesPerRoute) { socket.destroy(); return }
    const source = sourceKey(socket.remoteAddress)
    if (heldOff(source)) { socket.destroy(); return }
    if (countPhone(source, 1) > LIMITS.phonesPerAddress) { countPhone(source, -1); socket.destroy(); return }
    socket.on('close', () => countPhone(source, -1))
    clearTimeout(socket.handshakeTimer)
    const id = base64url(crypto.randomBytes(12))
    socket.sourceKey = source
    // A connection the Mac opened in advance: no OPEN, no handshake while the
    // phone waits. One that has died since is skipped, not used.
    let ready
    while ((ready = entry.spares.shift()) && ready.destroyed) {}
    if (ready) {
      ready.write(`PHONE ${id} ${socket.remoteAddress ?? '?'}\n`)
      ready.write(hello)
      const raw = ready.carrier
      raw.setTimeout(0)
      splice(socket, ready, raw, entry, id)
      socket.resume()
      log('phone: spliced to a spare')
      return
    }
    socket.hello = hello
    const drop = () => { entry.pending.delete(id); pendingByID.delete(id) }
    socket.pendingTimer = setTimeout(() => { drop(); socket.destroy() }, LIMITS.pendingMs)
    // A phone that gives up while its Mac is still answering frees its slot.
    socket.once('close', () => { clearTimeout(socket.pendingTimer); if (pendingByID.has(id)) drop() })
    entry.pending.set(id, socket)
    pendingByID.set(id, { phone: socket, entry })
    // The address goes to the Mac so its away listener can count a failed
    // handshake against this phone rather than against the loopback the pump
    // arrives from. Not a line the Mac parses for anything else.
    entry.socket.write(`OPEN ${id} ${socket.remoteAddress ?? '?'}\n`)
  }

  // MARK: UDP relaying
  //
  // The TCP splice stalls the whole stream on every lost packet, and the
  // phone's uplink to this relay was measured losing ~24% from 5G in Shanghai
  // (2026-10-05). So a Mac may also ask, over its own authenticated TLS, for a
  // UDP pair:  → UDP <token>   ← UDP-OK <token> <port>
  // where <token> is 16 random bytes, base64url, that only that Mac and its
  // phone (inside their end-to-end TLS) ever see. Each datagram then reads
  //   'NU1' | role ('M' or 'P') | token (16 bytes) | payload
  // and the relay forwards the payload, unread, to the other role's last
  // address. The payload is the two ends' KCP tunnel, authenticated by them.
  const datagramPairs = new Map()
  const udp = dgram.createSocket({ type: 'udp6', ipv6Only: false })
  let udpPort = 0
  udp.on('error', () => {})
  udp.on('message', (message, from) => {
    if (message.length < 20 || message[0] !== 0x4e || message[1] !== 0x55 || message[2] !== 0x31) return
    const role = message[3]
    if (role !== 0x4d && role !== 0x50) return
    const pair = datagramPairs.get(message.subarray(4, 20).toString('base64url'))
    if (!pair) return
    const now = Date.now()
    if (now - pair.windowStart >= 1000) { pair.windowStart = now; pair.windowBytes = 0 }
    pair.windowBytes += message.length
    if (pair.windowBytes > LIMITS.datagramBytesPerSecond) return
    pair.lastSeen = now
    const me = role === 0x4d ? 'mac' : 'phone'
    pair[me] = { address: from.address, port: from.port }
    const other = pair[me === 'mac' ? 'phone' : 'mac']
    if (other && message.length > 20) udp.send(message.subarray(20), other.port, other.address)
  })
  const sweep = setInterval(() => {
    const now = Date.now()
    for (const [token, pair] of datagramPairs) {
      if (now - pair.lastSeen > LIMITS.datagramIdleMs) { datagramPairs.delete(token); pair.entry.datagramTokens?.delete(token) }
    }
  }, 30_000)
  sweep.unref?.()

  function openDatagramPair(entry, route, token) {
    if (!/^[A-Za-z0-9_-]{22}$/.test(token) || !udpPort) {
      entry.socket.write(`UDP-NO ${token.slice(0, 32)}\n`)
      return
    }
    entry.datagramTokens ??= new Set()
    if (entry.datagramTokens.size >= LIMITS.datagramPairsPerRoute) {
      const oldest = entry.datagramTokens.values().next().value
      entry.datagramTokens.delete(oldest)
      datagramPairs.delete(oldest)
    }
    entry.datagramTokens.add(token)
    datagramPairs.set(token, { entry, mac: null, phone: null, lastSeen: Date.now(), windowStart: Date.now(), windowBytes: 0 })
    entry.socket.write(`UDP-OK ${token} ${udpPort}\n`)
    log(`host: ${route} opened a UDP pair`)
  }

  const server = net.createServer((socket) => {
    socket.setNoDelay(true)
    socket.setKeepAlive(true, 5_000)
    socket.on('error', () => {})
    socket.handshakeTimer = setTimeout(() => socket.destroy(), LIMITS.handshakeMs)
    const address = sourceKey(socket.remoteAddress)
    if (unidentified >= LIMITS.unidentifiedTotal) return socket.destroy()
    if (count(unidentifiedByAddress, address, 1) > LIMITS.unidentifiedPerAddress) {
      count(unidentifiedByAddress, address, -1)
      return socket.destroy()
    }
    unidentified += 1
    let identified = false
    const identify = () => { if (!identified) { identified = true; unidentified -= 1; count(unidentifiedByAddress, address, -1) } }
    socket.once('close', identify)
    // Chunks kept and joined only once the whole TLS record has arrived.
    const chunks = []
    let length = 0
    let needed = 0
    const first = (chunk) => {
      chunks.push(chunk)
      length += chunk.length
      // Everything here is TLS: a phone's ClientHello for the Mac, or a
      // Mac's for this relay. Anything else is nothing this knows.
      if (chunks[0][0] !== 0x16) return socket.destroy()
      if (needed === 0 && length >= 5) {
        const header = Buffer.concat(chunks, length).subarray(0, 5)
        needed = 5 + header.readUInt16BE(3)
      }
      if (length > LIMITS.helloBytes || needed > LIMITS.helloBytes + 5) return socket.destroy()
      if (needed === 0 || length < needed) return
      const buffered = Buffer.concat(chunks, length)
      const route = clientRoute(buffered)
      if (route === undefined) return socket.destroy()
      identify()
      socket.off('data', first)
      socket.pause()
      if (route) return phone(socket, buffered, route)
      // A Mac: terminate its TLS here and read lines from inside it.
      const secure = terminate(socket, buffered, identity)
      secure.once('secure', () => {
        firstLine(secure, Buffer.alloc(0), (line, rest) => {
          if (line.startsWith('NIMLET-HOST ')) host(secure, socket, address, line, rest)
          else if (line.startsWith('NIMLET-DATA ')) data(secure, socket, line, rest)
          else if (line.startsWith('NIMLET-SPARE ')) { secure.carrier = socket; spare(secure, socket, line) }
          else socket.destroy()
        })
        queueMicrotask(() => secure.resume())
      })
    }
    socket.on('data', first)
  })
  server.maxConnections = LIMITS.connections
  // UDP on the same port number as TCP, once TCP knows which that is.
  server.on('listening', () => {
    const { port } = server.address()
    udp.bind(port, () => { udpPort = udp.address().port })
  })
  server.on('close', () => { clearInterval(sweep); try { udp.close() } catch {} })
  server.datagramPairs = datagramPairs
  server.routes = routes
  server.backoff = backoff
  server.fingerprint = identity.fingerprint
  return server
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const option = (name) => { const at = process.argv.indexOf(name); return at > 0 ? process.argv[at + 1] : undefined }
  const port = Number(option('--port') ?? 7443)
  const keyPath = option('--key')
  if (!keyPath) {
    console.error('usage: relay.mjs --port 7443 --key /path/to/relay-key.pem   (made on first run)')
    process.exit(2)
  }
  const identity = relayIdentity(loadOrCreateKey(keyPath))
  const relay = createRelay({ identity, log: (line) => console.error(new Date().toISOString(), line) })
  // One line, so a parent process can read both from the first read:
  // the port it got, and the fingerprint every Mac has to be told.
  relay.listen(port, () => console.log(`listening ${relay.address().port} ${identity.fingerprint}`))
}
