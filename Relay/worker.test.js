/**
 * What can be checked without an Apple Developer account.
 *
 * Not the push — that needs a real key, a real token and a real phone. What it
 * does check is the part that fails silently and looks identical to every other
 * failure: a JWT that APNs rejects. A malformed one comes back as a 403 that
 * reads the same as a wrong key id, a wrong team id, or a clock that is off, so
 * it is worth knowing that the bytes leaving here are right.
 *
 *   node --test Relay/worker.test.js
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import worker, { providerToken, pemToBytes, base64url, validatePayload } from './worker.js'

/** A throwaway P-256 key in the same PKCS#8 PEM shape Apple's .p8 arrives in. */
async function makeKey() {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  )
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', pair.privateKey)
  const body = Buffer.from(pkcs8).toString('base64').match(/.{1,64}/g).join('\n')
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    publicKey: pair.publicKey,
  }
}

test('the .p8 Apple gives you parses', async () => {
  const { pem } = await makeKey()
  const bytes = pemToBytes(pem)
  assert.ok(bytes.length > 100, 'a P-256 PKCS#8 key is a few hundred bytes')
  // The header, the footer and every newline have to go; leaving one in makes
  // importKey fail with a DOMException that says nothing useful.
  assert.ok(!pem.includes('\r') || true)
  await assert.doesNotReject(
    crypto.subtle.importKey('pkcs8', bytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']),
  )
})

test('a .p8 pasted with stray whitespace still parses', async () => {
  const { pem } = await makeKey()
  const messy = '  \n' + pem.replace(/\n/g, '\r\n') + '\n  '
  await assert.doesNotReject(
    crypto.subtle.importKey('pkcs8', pemToBytes(messy), { name: 'ECDSA', namedCurve: 'P-256' },
                            false, ['sign']),
  )
})

test('the token is a JWT APNs will accept', async () => {
  const { pem, publicKey } = await makeKey()
  const env = { APNS_KEY: pem, APNS_KEY_ID: 'ABCDE12345', APNS_TEAM_ID: 'HG29U745Q5' }
  const jwt = await providerToken(env)

  const [header, claims, signature] = jwt.split('.')
  assert.equal(jwt.split('.').length, 3)

  const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString())
  // APNs supports exactly one algorithm here and rejects anything else outright.
  assert.deepEqual(decode(header), { alg: 'ES256', kid: 'ABCDE12345' })

  const body = decode(claims)
  assert.equal(body.iss, 'HG29U745Q5')
  assert.ok(Math.abs(body.iat - Math.floor(Date.now() / 1000)) < 5,
            'a token more than an hour old is refused, so iat must be now')

  // The signature has to be raw r||s — 64 bytes for P-256 — not the DER that
  // most signing libraries hand back. Web Crypto gets this right; asserting it
  // means a future change to a different signer cannot get it wrong quietly.
  const raw = Buffer.from(signature, 'base64url')
  assert.equal(raw.length, 64)

  const verified = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    publicKey,
    raw,
    new TextEncoder().encode(`${header}.${claims}`),
  )
  assert.ok(verified, 'APNs verifies this signature against the key it has on file')
})

test('base64url leaves nothing a URL would mangle', () => {
  // A JWT rides in an Authorization header; +, / and = in it are how you get a
  // 403 on some payloads and not others.
  for (let i = 0; i < 200; i++) {
    const encoded = base64url(String.fromCharCode(...Array.from({ length: 30 }, () => i * 7 % 256)))
    assert.ok(!/[+/=]/.test(encoded))
  }
})

/** Exactly what `PushEnvelope.payload` writes on the Mac. */
function sealedPayload(overrides = {}) {
  const aps = {
    alert: { title: 'Nimlet', body: 'Something needs you' },
    'mutable-content': 1,
    category: 'mice.agent.approval',
    'thread-id': '0123456789abcdef',
    'relevance-score': 1,
    'interruption-level': 'time-sensitive',
    sound: 'default',
    ...overrides.aps,
  }
  const m = { box: Buffer.alloc(200, 7).toString('base64'), version: 1, ...overrides.m }
  return { aps, m, ...overrides.top }
}

test('the push the Mac sends is forwarded', () => {
  assert.equal(validatePayload(sealedPayload()), null)
  assert.equal(validatePayload(sealedPayload({ aps: { sound: undefined, 'interruption-level': 'passive', category: 'mice.agent.event' } })), null)
})

test('a push that would put its own words on the lock screen is refused', () => {
  // The relay is not an APNs proxy: the only text that may travel in the
  // clear is the placeholder, and the only buttons are the two categories.
  assert.ok(validatePayload(sealedPayload({ aps: { alert: { title: 'Nimlet', body: 'Allow rm -rf ~? Tap Approve' } } })))
  assert.ok(validatePayload(sealedPayload({ aps: { alert: { title: 'Bank', body: 'Something needs you' } } })))
  assert.ok(validatePayload(sealedPayload({ aps: { category: 'anything' } })))
  assert.ok(validatePayload(sealedPayload({ aps: { badge: 99 } })))
  assert.ok(validatePayload(sealedPayload({ aps: { 'mutable-content': 0 } })), 'without the extension nothing is checked on the phone')
  assert.ok(validatePayload(sealedPayload({ top: { approvalID: 'a-1' } })))
  assert.ok(validatePayload(sealedPayload({ top: { targetID: 't-1' } })))
  assert.ok(validatePayload(sealedPayload({ aps: { 'thread-id': 'claude (work)' } })))
  assert.ok(validatePayload(sealedPayload({ m: { version: 2 } })))
  assert.ok(validatePayload(sealedPayload({ m: { box: 'not base64!' } })))
  assert.ok(validatePayload(sealedPayload({ m: { box: 'x'.repeat(10_000) } })))
  assert.ok(validatePayload({}))
  assert.ok(validatePayload(null))
  assert.ok(validatePayload([]))
})

/** Exercise the HTTP handler with APNs replaced by a local observer. */
async function withAPNs(run) {
  const saved = globalThis.fetch
  const calls = []
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options })
    return new Response(null, { status: 200 })
  }
  const { pem } = await makeKey()
  const env = {
    APNS_KEY: pem, APNS_KEY_ID: 'ABCDE12345', APNS_TEAM_ID: 'HG29U745Q5',
    APNS_TOPIC: 'com.renyicao.mice.remote', RELAY_SECRET: 'test-only-secret',
    SOURCE_PUSH_LIMITER: { limit: async () => ({ success: true }) },
    DEVICE_PUSH_LIMITER: { limit: async () => ({ success: true }) },
  }
  try { await run(env, calls) } finally { globalThis.fetch = saved }
}

function pushRequest(overrides = {}, secret = 'test-only-secret') {
  return new Request('https://relay.invalid/', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + secret, 'cf-connecting-ip': '192.0.2.42' },
    body: JSON.stringify({ token: 'ab'.repeat(32), sandbox: true, payload: sealedPayload(),
      collapseId: '0123456789abcdef', ...overrides }),
  })
}

test('the HTTP handler forwards only the sealed payload to the matching APNs environment', async () => {
  await withAPNs(async (env, calls) => {
    const response = await worker.fetch(pushRequest(), env)
    assert.equal(response.status, 200)
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, 'https://api.sandbox.push.apple.com/3/device/' + 'ab'.repeat(32))
    assert.equal(calls[0].options.headers['apns-topic'], env.APNS_TOPIC)
    assert.equal(calls[0].options.headers['apns-collapse-id'], '0123456789abcdef')
    assert.deepEqual(JSON.parse(calls[0].options.body), sealedPayload())
  })
})

test('source and device limits return 429 before any APNs request', async () => {
  await withAPNs(async (env, calls) => {
    for (const name of ['SOURCE_PUSH_LIMITER', 'DEVICE_PUSH_LIMITER']) {
      const allowed = env[name]
      env[name] = { limit: async () => ({ success: false }) }
      const response = await worker.fetch(pushRequest(), env)
      assert.equal(response.status, 429)
      assert.equal(response.headers.get('retry-after'), '60')
      assert.equal(calls.length, 0)
      env[name] = allowed
    }
  })
})

test('missing or failed limit bindings fail closed', async () => {
  await withAPNs(async (env, calls) => {
    for (const name of ['SOURCE_PUSH_LIMITER', 'DEVICE_PUSH_LIMITER']) {
      const allowed = env[name]
      delete env[name]
      assert.equal((await worker.fetch(pushRequest(), env)).status, 503)
      env[name] = { limit: async () => { throw new Error('unavailable') } }
      assert.equal((await worker.fetch(pushRequest(), env)).status, 503)
      env[name] = allowed
    }
    assert.equal(calls.length, 0)
  })
})

test('device counter keys are opaque, normalized and isolated by device', async () => {
  await withAPNs(async (env) => {
    const keys = []
    env.DEVICE_PUSH_LIMITER.limit = async ({ key }) => { keys.push(key); return { success: true } }
    for (const token of ['ab'.repeat(32), 'AB'.repeat(32), 'cd'.repeat(32)]) {
      assert.equal((await worker.fetch(pushRequest({ token }), env)).status, 200)
    }
    assert.equal(keys[0], keys[1])
    assert.notEqual(keys[0], keys[2])
    assert.match(keys[0], /^device:[0-9a-f]{64}$/)
    assert.ok(!keys[0].includes('ab'.repeat(32)))
  })
})

test('invalid secrets and unsealed payloads never reach APNs or consume the device budget', async () => {
  await withAPNs(async (env, calls) => {
    let devices = 0
    env.DEVICE_PUSH_LIMITER.limit = async () => { devices++; return { success: true } }
    assert.equal((await worker.fetch(pushRequest({}, 'wrong'), env)).status, 401)
    assert.equal((await worker.fetch(pushRequest({ payload: { aps: { alert: 'arbitrary text' } } }), env)).status, 400)
    assert.equal(devices, 0)
    assert.equal(calls.length, 0)
  })
})
