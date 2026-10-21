/**
 * The connect relay, end to end on loopback, without an Apple device.
 *
 * The TLS that passes through it is checked from Swift (`RelayLinkTests`),
 * against the real Network.framework stacks at both ends. What is checked here
 * is the relay's own half: that it finds the route in a real ClientHello, that
 * only the holder of a key can register its route, that a Mac's connection is
 * TLS to a key the Mac can pin, and that the bytes a phone sends arrive at the
 * Mac exactly as sent, ClientHello first.
 *
 *   node --test Relay/connect/relay.test.mjs
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import tls from 'node:tls'
import crypto from 'node:crypto'
import { createRelay, serverName, clientRoute, routeFor, base64url, sourceKey, relayIdentity, LIMITS, SNI_SUFFIX } from './relay.mjs'

const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))

/** Reads lines off a socket, one promise per line. */
function lineReader(socket) {
  let buffer = ''
  const waiting = []
  socket.on('data', (chunk) => {
    buffer += chunk.toString('utf8')
    let newline
    while ((newline = buffer.indexOf('\n')) >= 0 && waiting.length) {
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      waiting.shift()(line)
    }
  })
  return () => new Promise((resolve) => {
    const newline = buffer.indexOf('\n')
    if (newline >= 0) { const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1); resolve(line) }
    else waiting.push(resolve)
  })
}

/** A real ClientHello, as Node's TLS stack writes one, naming `name`. */
async function clientHello(name, ALPNProtocols) {
  const sink = net.createServer()
  const port = await listen(sink)
  const bytes = new Promise((resolve) => sink.once('connection', (s) => s.once('data', resolve)))
  const client = tls.connect({ host: '127.0.0.1', port, servername: name, ALPNProtocols, rejectUnauthorized: false })
  client.on('error', () => {})
  const hello = await bytes
  client.destroy(); sink.close()
  return hello
}

/** What a Mac does: TLS to the relay, checking nothing but the key. */
function macSocket(port, { expectFingerprint } = {}) {
  const socket = tls.connect({
    host: '127.0.0.1', port, rejectUnauthorized: false, minVersion: 'TLSv1.3',
  })
  socket.on('error', () => {})
  if (expectFingerprint) {
    socket.once('secureConnect', () => {
      const presented = fingerprintOf(socket.getPeerCertificate())
      if (presented !== expectFingerprint) socket.destroy(new Error('wrong relay key'))
    })
  }
  return socket
}

/** SHA-256 of the key's uncompressed point, base64url: `TrustFingerprint`. */
function fingerprintOf(peerCertificate) {
  const jwk = new crypto.X509Certificate(peerCertificate.raw).publicKey.export({ format: 'jwk' })
  const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')])
  return crypto.createHash('sha256').update(point).digest('base64url')
}

/** A Mac: a P-256 key, registered over a control connection. */
async function registerMac(port, { key = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' }), forge = false, expectFingerprint, spares = false } = {}) {
  const jwk = key.publicKey.export({ format: 'jwk' })
  const x963 = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')])
  const control = macSocket(port, { expectFingerprint })
  const next = lineReader(control)
  control.write(`NIMLET-HOST 1 ${base64url(x963)}${spares ? ' spares' : ''}\n`)
  const [word, nonce] = (await next()).split(' ')
  assert.equal(word, 'CHALLENGE')
  const signer = forge ? crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey : key.privateKey
  const signature = crypto.sign('sha256', Buffer.concat([Buffer.from('nimlet-relay-v1:'), Buffer.from(nonce, 'base64url')]), signer)
  control.write(`PROOF ${base64url(signature)}\n`)
  return { control, next, route: routeFor(x963) }
}

const closed = (socket) => new Promise((resolve) => socket.once('close', resolve))

test('reads the server name out of a real ClientHello', async () => {
  const hello = await clientHello(`0123456789abcdef0123456789abcdef01234567${SNI_SUFFIX}`)
  assert.equal(serverName(hello), `0123456789abcdef0123456789abcdef01234567${SNI_SUFFIX}`)
  assert.equal(serverName(hello.subarray(0, 20)), undefined, 'a partial hello is "not yet", not "never"')
  assert.equal(serverName(Buffer.from('GET / HTTP/1.1\r\n')), null)
})

test('routes ALPN without a synthetic SNI and retains legacy SNI', async () => {
  const route = '0123456789abcdef0123456789abcdef01234567'
  const hello = await clientHello(undefined, ['h2', `nimlet-${route}`])
  assert.equal(serverName(hello), null)
  assert.equal(clientRoute(hello), route)
  assert.equal(clientRoute(hello.subarray(0, 20)), undefined)
  assert.equal(clientRoute(await clientHello(`${route}${SNI_SUFFIX}`)), route)
  assert.equal(clientRoute(await clientHello(undefined, ['h2'])), null)
})

test('refuses conflicting routes and malformed TLS extension boundaries', async () => {
  const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  const b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  assert.equal(clientRoute(await clientHello(undefined, [`nimlet-${a}`, `nimlet-${b}`])), null)
  assert.equal(clientRoute(await clientHello(`${a}${SNI_SUFFIX}`, [`nimlet-${b}`])), null)
  const broken = Buffer.from(await clientHello(undefined, [`nimlet-${a}`]))
  broken[8] ^= 1 // ClientHello length cannot escape its TLS record.
  assert.equal(clientRoute(broken), null)
})

test('the relay presents a key the Mac can pin, as a certificate TLS accepts', async () => {
  const identity = relayIdentity()
  const relay = createRelay({ identity })
  const port = await listen(relay)
  assert.equal(relay.fingerprint, identity.fingerprint)
  assert.match(identity.fingerprint, /^[A-Za-z0-9_-]{43}$/, 'base64url of 32 bytes, no padding — what TrustFingerprint prints')

  const mac = await registerMac(port, { expectFingerprint: identity.fingerprint })
  assert.equal(await mac.next(), `OK ${mac.route}`)
  assert.equal(mac.control.getProtocol(), 'TLSv1.3')

  // A relay with a different key is refused by a Mac pinning this one.
  const other = createRelay({ identity: relayIdentity() })
  const otherPort = await listen(other)
  const refused = macSocket(otherPort, { expectFingerprint: identity.fingerprint })
  await closed(refused)
  assert.equal(other.routes.size, 0)

  mac.control.destroy(); relay.close(); other.close()
})

test('a Mac registers under the route its key implies, and only with that key', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  assert.ok(relay.routes.has(mac.route))

  const forger = await registerMac(port, { forge: true })
  await closed(forger.control)
  assert.equal(relay.routes.size, 1, 'a signature from another key registers nothing')
  mac.control.destroy(); relay.close()
})

test('a Mac that speaks plain TCP, or anything but TLS, gets nothing', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const plain = net.connect(port, '127.0.0.1')
  plain.on('error', () => {})
  plain.write('NIMLET-HOST 1 whatever\n')
  await closed(plain)
  assert.equal(relay.routes.size, 0)
  relay.close()
})

for (const mode of ['SNI', 'ALPN']) test(`${mode}: a phone's bytes reach the Mac intact, and the Mac's reach the phone`, async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)

  const hello = mode === 'SNI' ? await clientHello(`${mac.route}${SNI_SUFFIX}`)
    : await clientHello(undefined, [`nimlet-${mac.route}`])
  const phone = net.connect(port, '127.0.0.1')
  phone.write(hello)

  const [word, id, address] = (await mac.next()).split(' ')
  assert.equal(word, 'OPEN')
  assert.equal(address, '127.0.0.1', 'the Mac is told where the phone came from')
  const data = macSocket(port)
  data.write(`NIMLET-DATA 1 ${id}\n`)
  let received = Buffer.alloc(0)
  const gotHello = new Promise((resolve) => data.on('data', (chunk) => {
    received = Buffer.concat([received, chunk])
    if (received.length >= hello.length) resolve()
  }))
  await gotHello
  assert.deepEqual(received.subarray(0, hello.length), hello)

  const reply = new Promise((resolve) => phone.once('data', resolve))
  data.write('server hello, more or less')
  assert.equal((await reply).toString(), 'server hello, more or less')
  phone.destroy(); data.destroy(); mac.control.destroy(); relay.close()
})

test('a phone naming a route nobody holds is closed, and opens nothing', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const phone = net.connect(port, '127.0.0.1')
  phone.on('error', () => {})
  phone.write(await clientHello(`ffffffffffffffffffffffffffffffffffffffff${SNI_SUFFIX}`))
  await closed(phone)
  relay.close()
})

test('a key padded with extra bytes does not buy a second route', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const key = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const jwk = key.publicKey.export({ format: 'jwk' })
  const padded = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url'), Buffer.from([0])])
  const control = macSocket(port)
  control.write(`NIMLET-HOST 1 ${base64url(padded)}\n`)
  await closed(control)
  assert.equal(relay.routes.size, 0)
  relay.close()
})

test('one address can hold only a few routes', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const macs = []
  for (let i = 0; i < 4; i++) {
    const mac = await registerMac(port)
    assert.equal(await mac.next(), `OK ${mac.route}`)
    macs.push(mac)
  }
  const fifth = await registerMac(port)
  await closed(fifth.control)
  assert.equal(relay.routes.size, 4)
  macs.forEach((mac) => mac.control.destroy())
  relay.close()
})

test('a phone whose splices keep dying young is held off', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  const hello = await clientHello(`${mac.route}${SNI_SUFFIX}`)
  const otherMac = await registerMac(port)
  assert.equal(await otherMac.next(), `OK ${otherMac.route}`)

  // Three splices the "Mac" closes at once: what a stranger's ClientHello
  // gets from an away listener that does not know its key.
  for (let i = 0; i < LIMITS.failuresBeforeBackoff; i++) {
    const phone = net.connect(port, '127.0.0.1')
    phone.on('error', () => {})
    phone.write(hello)
    const [, id] = (await mac.next()).split(' ')
    const data = macSocket(port)
    data.write(`NIMLET-DATA 1 ${id}\n`)
    await new Promise((resolve) => data.once('data', resolve))
    // Another authenticated Mac cannot exempt somebody else's splice.
    otherMac.control.write(`VERIFIED ${id}\n`)
    data.destroy()
    await closed(phone)
  }
  await new Promise((resolve) => setTimeout(resolve, LIMITS.shortSpliceMs + 50))
  assert.ok(relay.backoff.get(sourceKey('127.0.0.1')).until > Date.now())

  // The next one is refused at the door, and the Mac never hears OPEN.
  const phone = net.connect(port, '127.0.0.1')
  phone.on('error', () => {})
  phone.write(hello)
  await closed(phone)
  let opened = false
  mac.next().then(() => { opened = true })
  await new Promise((resolve) => setTimeout(resolve, 100))
  assert.equal(opened, false)
  otherMac.control.destroy(); mac.control.destroy(); relay.close()
})

test('per-source limits see an IPv6 /64 as one source and an IPv4 address as itself', () => {
  assert.equal(sourceKey('2001:db8:1:2:aaaa:bbbb:cccc:dddd'), sourceKey('2001:db8:1:2:1:2:3:4'))
  assert.notEqual(sourceKey('2001:db8:1:2::1'), sourceKey('2001:db8:1:3::1'))
  assert.equal(sourceKey('::ffff:203.0.113.9'), '203.0.113.9')
  assert.notEqual(sourceKey('203.0.113.9'), sourceKey('203.0.113.10'), 'a carrier NAT puts thousands behind one address; the /24 would be them all')
})

test('quick splices verified by their own Mac do not penalize a paired phone', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  const hello = await clientHello(undefined, [`nimlet-${mac.route}`])
  for (let i = 0; i < 6; i++) {
    const phone = net.connect(port, '127.0.0.1')
    phone.on('error', () => {})
    phone.write(hello)
    const [, id] = (await mac.next()).split(' ')
    const data = macSocket(port)
    data.write(`NIMLET-DATA 1 ${id}\n`)
    await new Promise((resolve) => data.once('data', resolve))
    data.destroy()
    await closed(phone)
    // Confirmation can arrive on control after the data socket closes.
    mac.control.write(`VERIFIED ${id}\n`)
  }
  await new Promise((resolve) => setTimeout(resolve, LIMITS.shortSpliceMs + 50))
  assert.equal(relay.backoff.size, 0)
  mac.control.destroy(); relay.close()
})

test('a phone cancelling losing connection races is not an authentication failure', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  const hello = await clientHello(undefined, [`nimlet-${mac.route}`])
  for (let i = 0; i < 6; i++) {
    const phone = net.connect(port, '127.0.0.1')
    phone.on('error', () => {})
    phone.write(hello)
    const [, id] = (await mac.next()).split(' ')
    const data = macSocket(port)
    data.write(`NIMLET-DATA 1 ${id}\n`)
    await new Promise((resolve) => data.once('data', resolve))
    phone.destroy()
    await closed(data)
  }
  await new Promise((resolve) => setTimeout(resolve, LIMITS.shortSpliceMs + 50))
  assert.equal(relay.backoff.size, 0)
  mac.control.destroy(); relay.close()
})

// MARK: - Spares

/** A spare connection: TLS to the relay, parked on a route with its token. */
async function parkSpare(port, route, token) {
  const spare = macSocket(port)
  await new Promise((resolve) => spare.once('secureConnect', resolve))
  // Listened for before the line goes: a refusal can close it at once.
  spare.gone = closed(spare)
  spare.write(`NIMLET-SPARE 1 ${route} ${token}\n`)
  return spare
}

const until = async (predicate, ms = 2000) => {
  const end = Date.now() + ms
  while (!predicate() && Date.now() < end) await new Promise((resolve) => setTimeout(resolve, 10))
  return predicate()
}

test('a Mac that does not ask for spares is answered exactly as before', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  mac.control.destroy(); relay.close()
})

test('a waiting spare carries the next phone with no OPEN and no handshake in between', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port, { spares: true })
  const [word, route, token] = (await mac.next()).split(' ')
  assert.equal(word, 'OK'); assert.equal(route, mac.route); assert.ok(token?.length >= 32)
  const spare = await parkSpare(port, route, token)
  assert.ok(await until(() => relay.routes.get(route)?.spares.length === 1))

  let opened = false
  mac.next().then(() => { opened = true })
  const hello = await clientHello(undefined, [`nimlet-${mac.route}`])
  const phone = net.connect(port, '127.0.0.1')
  phone.write(hello)
  const read = lineReader(spare)
  const [phoneWord, id, address] = (await read()).split(' ')
  assert.equal(phoneWord, 'PHONE'); assert.ok(id); assert.equal(address, '127.0.0.1')
  // The ClientHello follows the line, intact.
  let received = Buffer.alloc(0)
  spare.removeAllListeners('data')
  await new Promise((resolve) => spare.on('data', (chunk) => {
    received = Buffer.concat([received, chunk]); if (received.length >= hello.length) resolve()
  }))
  assert.deepEqual(received.subarray(0, hello.length), hello)
  const reply = new Promise((resolve) => phone.once('data', resolve))
  spare.write('server hello, more or less')
  assert.equal((await reply).toString(), 'server hello, more or less')
  assert.equal(opened, false, 'no OPEN went to the Mac')
  assert.equal(relay.routes.get(route).spares.length, 0, 'the spare is used up')
  phone.destroy(); spare.destroy(); mac.control.destroy(); relay.close()
})

test('a spare with the wrong token, or for a Mac that asked for none, is closed', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const plain = await registerMac(port)
  assert.equal(await plain.next(), `OK ${plain.route}`)
  const withSpares = await registerMac(port, { spares: true })
  const [, route, token] = (await withSpares.next()).split(' ')
  const wrong = await parkSpare(port, route, token.slice(0, -2) + 'AA')
  const none = await parkSpare(port, plain.route, token)
  await Promise.all([wrong.gone, none.gone])
  assert.equal(relay.routes.get(route).spares.length, 0)
  plain.control.destroy(); withSpares.control.destroy(); relay.close()
})

test('with no spare left the relay falls back to OPEN, and spares die with their Mac', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port, { spares: true })
  const [, route, token] = (await mac.next()).split(' ')
  const spares = []
  for (let i = 0; i < LIMITS.sparesPerRoute + 1; i++) spares.push(await parkSpare(port, route, token))
  // One more than the limit: refused.
  await spares.pop().gone
  assert.ok(await until(() => relay.routes.get(route).spares.length === LIMITS.sparesPerRoute))
  const hello = await clientHello(undefined, [`nimlet-${mac.route}`])
  const phones = []
  for (let i = 0; i < LIMITS.sparesPerRoute + 1; i++) {
    const phone = net.connect(port, '127.0.0.1'); phone.on('error', () => {})
    phone.write(hello); phones.push(phone)
  }
  const [word] = (await mac.next()).split(' ')
  assert.equal(word, 'OPEN', 'the phone after the last spare is opened the old way')
  mac.control.destroy()
  await Promise.all(phones.map(closed))
  phones.forEach((p) => p.destroy()); spares.forEach((s) => s.destroy()); relay.close()
})

// MARK: - UDP pairs

import dgram from 'node:dgram'

const datagramHeader = (role, token) => Buffer.concat([Buffer.from('NU1'), Buffer.from(role), Buffer.from(token, 'base64url')])
function udpClient() {
  const socket = dgram.createSocket('udp4')
  const received = []
  socket.on('message', (message) => received.push(message.toString()))
  return { socket, received, send: (port, role, token, text) =>
    new Promise((resolve) => socket.send(Buffer.concat([datagramHeader(role, token), Buffer.from(text)]), port, '127.0.0.1', resolve)) }
}

test('a Mac can open a UDP pair, and the relay forwards between its two ends unread', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  const token = crypto.randomBytes(16).toString('base64url')
  mac.control.write(`UDP ${token}\n`)
  const [word, echoed, udpPort] = (await mac.next()).split(' ')
  assert.equal(word, 'UDP-OK'); assert.equal(echoed, token); assert.equal(Number(udpPort), port, 'same port number as TCP')
  const macEnd = udpClient(), phoneEnd = udpClient()
  await macEnd.send(port, 'M', token, 'hello from the Mac, before the phone')  // learns the Mac
  await phoneEnd.send(port, 'P', token, 'from the phone')
  assert.ok(await until(() => macEnd.received.includes('from the phone')))
  await macEnd.send(port, 'M', token, 'from the Mac')
  assert.ok(await until(() => phoneEnd.received.includes('from the Mac')))
  assert.ok(!phoneEnd.received.includes('hello from the Mac, before the phone'), 'nothing is buffered for an end not yet seen')
  macEnd.socket.close(); phoneEnd.socket.close(); mac.control.destroy(); relay.close()
})

test('an unknown token is dropped, a malformed one refused, and a pair dies with its Mac', async () => {
  const relay = createRelay()
  const port = await listen(relay)
  const mac = await registerMac(port)
  assert.equal(await mac.next(), `OK ${mac.route}`)
  mac.control.write('UDP not-a-token\n')
  assert.equal((await mac.next()).split(' ')[0], 'UDP-NO')
  const token = crypto.randomBytes(16).toString('base64url')
  mac.control.write(`UDP ${token}\n`)
  assert.equal((await mac.next()).split(' ')[0], 'UDP-OK')
  const stranger = crypto.randomBytes(16).toString('base64url')
  const a = udpClient(), b = udpClient()
  await a.send(port, 'M', stranger, 'x'); await b.send(port, 'P', stranger, 'y')
  await new Promise((resolve) => setTimeout(resolve, 100))
  assert.deepEqual([a.received, b.received], [[], []], 'a token nobody registered carries nothing')
  assert.equal(relay.datagramPairs.size, 1)
  mac.control.destroy()
  assert.ok(await until(() => relay.datagramPairs.size === 0), 'the Mac going away takes its pairs')
  a.socket.close(); b.socket.close(); relay.close()
})
