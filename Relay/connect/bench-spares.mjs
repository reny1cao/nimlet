/**
 * How long a phone waits for its Mac's first byte through the relay, with the
 * Mac dialling on OPEN versus a spare it opened in advance — on loopback, with
 * the round trips of the real path put back in by delaying proxies.
 *
 *   node Relay/connect/bench-spares.mjs [macRttMs=330] [phoneRttMs=150] [runs=8]
 *
 * Defaults are what was measured on 2026-10-05: the Mac in Shanghai to the
 * relay in Singapore through its VPN exit is ~330 ms; the phone's leg is a
 * guess at 5G to Singapore and only shifts both numbers equally.
 */
import net from 'node:net'
import tls from 'node:tls'
import crypto from 'node:crypto'
import { createRelay, routeFor, base64url } from './relay.mjs'

const [macRtt = 330, phoneRtt = 150, runs = 8] = process.argv.slice(2).map(Number)
const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))

/** Forwards to `port`, holding every chunk `oneWay` ms each direction. */
async function delayed(port, oneWay) {
  const proxy = net.createServer((inbound) => {
    const outbound = net.connect(port, '127.0.0.1')
    const hold = (from, to) => {
      from.on('data', (chunk) => setTimeout(() => to.write(chunk), oneWay))
      from.on('close', () => setTimeout(() => to.destroy(), oneWay))
      from.on('error', () => {})
    }
    // The SYN/ACK too: a connect takes a round trip.
    inbound.pause()
    outbound.once('connect', () => setTimeout(() => inbound.resume(), oneWay * 2))
    hold(inbound, outbound); hold(outbound, inbound)
  })
  return listen(proxy)
}

/** A connect through a delaying proxy: pay the round trip before `connect` fires. */
function connectVia(port, oneWay, options = {}) {
  return new Promise((resolve) => {
    const raw = net.connect(port, '127.0.0.1')
    raw.once('connect', () => setTimeout(() => {
      if (!options.tls) return resolve(raw)
      const secure = tls.connect({ socket: raw, rejectUnauthorized: false, minVersion: 'TLSv1.3' }, () => resolve(secure))
      secure.on('error', () => {})
    }, oneWay * 2))
    raw.on('error', () => {})
  })
}

function lines(socket) {
  let buffer = ''
  const waiting = []
  const flush = () => {
    let newline
    while (waiting.length && (newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1); waiting.shift()(line)
    }
  }
  socket.on('data', (chunk) => { buffer += chunk.toString(); flush() })
  return () => new Promise((resolve) => { waiting.push(resolve); flush() })
}

async function clientHello(route) {
  const sink = net.createServer()
  const port = await listen(sink)
  const bytes = new Promise((resolve) => sink.once('connection', (s) => s.once('data', resolve)))
  const client = tls.connect({ host: '127.0.0.1', port, ALPNProtocols: [`nimlet-${route}`], rejectUnauthorized: false })
  client.on('error', () => {})
  const hello = await bytes
  client.destroy(); sink.close()
  return hello
}

async function run(useSpares) {
  const relay = createRelay()
  const port = await listen(relay)
  const macSide = await delayed(port, macRtt / 2)
  const phoneSide = await delayed(port, phoneRtt / 2)
  const key = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const jwk = key.publicKey.export({ format: 'jwk' })
  const x963 = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')])
  const route = routeFor(x963)
  const control = await connectVia(macSide, macRtt / 2, { tls: true })
  const next = lines(control)
  control.write(`NIMLET-HOST 1 ${base64url(x963)}${useSpares ? ' spares' : ''}\n`)
  const [, nonce] = (await next()).split(' ')
  control.write(`PROOF ${base64url(crypto.sign('sha256', Buffer.concat([Buffer.from('nimlet-relay-v1:'), Buffer.from(nonce, 'base64url')]), key.privateKey))}\n`)
  const [, , token] = (await next()).split(' ')

  // The Mac's side: answer every phone with one byte, by OPEN or by spare.
  const answer = (socket) => socket.once('data', () => socket.write('!'))
  const park = async () => {
    const spare = await connectVia(macSide, macRtt / 2, { tls: true })
    spare.write(`NIMLET-SPARE 1 ${route} ${token}\n`)
    let seen = false
    spare.on('data', (chunk) => { if (!seen && chunk.includes(0x0a)) { seen = true; spare.write('!'); park() } })
  }
  if (useSpares) { await park(); await park() }
  ;(async () => {
    for (;;) {
      const line = await next()
      if (!line.startsWith('OPEN ')) continue
      const data = await connectVia(macSide, macRtt / 2, { tls: true })
      data.write(`NIMLET-DATA 1 ${line.split(' ')[1]}\n`)
      answer(data)
    }
  })()
  await new Promise((resolve) => setTimeout(resolve, macRtt * 2))

  const hello = await clientHello(route)
  const times = []
  for (let i = 0; i < runs; i++) {
    const phone = await connectVia(phoneSide, phoneRtt / 2)
    const started = performance.now()
    const reply = new Promise((resolve) => phone.once('data', resolve))
    phone.write(hello)
    await reply
    times.push(performance.now() - started)
    phone.destroy()
    await new Promise((resolve) => setTimeout(resolve, macRtt * 3))
  }
  control.destroy(); relay.close()
  times.sort((a, b) => a - b)
  return { median: times[Math.floor(times.length / 2)], max: times[times.length - 1] }
}

const open = await run(false)
const spare = await run(true)
console.log(`Mac↔relay RTT ${macRtt} ms, phone↔relay RTT ${phoneRtt} ms: ClientHello → Mac's first byte`)
console.log(`  OPEN : median ${open.median.toFixed(0)} ms, max ${open.max.toFixed(0)} ms`)
console.log(`  spare: median ${spare.median.toFixed(0)} ms, max ${spare.max.toFixed(0)} ms`)
console.log(`  saved per relayed socket: ${(open.median - spare.median).toFixed(0)} ms`)
process.exit(0)
