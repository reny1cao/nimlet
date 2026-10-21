/**
 * The one piece of Nimlet that does not run on your own machines.
 *
 * It exists for a single reason. A push has to be signed with the APNs key,
 * and that key belongs to the team that owns the bundle id — not to you, and
 * not to your Mac. Shipping it inside the Mac app would hand every copy the
 * ability to push to every other user's phone. So one thing has to hold it.
 *
 * This is that thing, and it is deliberately the least it can be:
 *
 *   - **Stateless.** No database, no device registry, no accounts. Device
 *     tokens live on the Mac that was paired with the phone; they are handed
 *     over one at a time, used once, and forgotten.
 *   - **Blind.** The `payload` it forwards was built and sealed on the Mac with
 *     a key this worker has never seen — one of the 256-bit per-device keys
 *     Nimlet already issues at pairing. What is readable here is an opaque device
 *     token, a length and a clock. Not which target, not which agent, not what
 *     it said, not what command it wanted to run.
 *   - **Dumb.** It does not decide anything. Every judgement about whether
 *     somebody should be interrupted was made by `AlertPolicy` on the Mac,
 *     against rules the phone sent it.
 *
 * Deploy: see Relay/README.md. Four secrets and one `wrangler deploy`.
 */

const APNS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
}

/** A provider token is good for an hour; Apple rejects one older than that and
 *  rate-limits minting them. Workers keep an isolate warm between requests, so
 *  caching it here costs nothing and usually saves the signature. */
let cachedToken = null

async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000)
  // Renewed at fifty minutes rather than sixty: a token that expires in flight
  // comes back as a 403 that looks exactly like a misconfigured key.
  if (cachedToken && now - cachedToken.issuedAt < 50 * 60) return cachedToken.jwt

  const header = { alg: 'ES256', kid: env.APNS_KEY_ID }
  const claims = { iss: env.APNS_TEAM_ID, iat: now }
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(env.APNS_KEY),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signingInput),
  )

  const jwt = `${signingInput}.${base64urlBytes(new Uint8Array(signature))}`
  cachedToken = { jwt, issuedAt: now }
  return jwt
}

/**
 * The one shape of push the Mac ever sends, and the only one this forwards.
 *
 * Without this the worker is an APNs proxy for the app's topic: anybody with
 * the bearer secret — which ships inside the Mac app — and a device token
 * could send that phone a notification saying whatever they liked, with
 * Approve and Deny buttons on it. The sealed box inside is what the phone
 * trusts; everything around it is pinned here to exactly what
 * `PushEnvelope.payload` writes, so the only words that can reach a lock
 * screen through this relay are the fixed placeholder and what a paired Mac
 * sealed. Returns a reason, or null for a payload that is as it should be.
 */
export function validatePayload(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return 'no payload'
  const keys = Object.keys(payload).sort()
  if (keys.join(',') !== 'aps,m') return 'unexpected keys'
  const { aps, m } = payload
  if (!aps || typeof aps !== 'object') return 'no aps'
  const allowed = ['alert', 'mutable-content', 'category', 'thread-id', 'relevance-score', 'interruption-level', 'sound']
  if (Object.keys(aps).some((key) => !allowed.includes(key))) return 'unexpected aps key'
  if (!aps.alert || typeof aps.alert !== 'object'
      || Object.keys(aps.alert).sort().join(',') !== 'body,title'
      || aps.alert.title !== PLACEHOLDER.title || aps.alert.body !== PLACEHOLDER.body) return 'alert is not the placeholder'
  if (aps['mutable-content'] !== 1) return 'not mutable'
  if (!CATEGORIES.includes(aps.category)) return 'bad category'
  if (!/^[0-9a-f]{16}$/.test(String(aps['thread-id']))) return 'bad thread-id'
  if (typeof aps['relevance-score'] !== 'number' || !(aps['relevance-score'] >= 0 && aps['relevance-score'] <= 1)) return 'bad relevance'
  if (!['time-sensitive', 'passive'].includes(aps['interruption-level'])) return 'bad interruption level'
  if (aps.sound !== undefined && aps.sound !== 'default') return 'bad sound'
  if (!m || typeof m !== 'object' || Object.keys(m).sort().join(',') !== 'box,version') return 'bad box'
  if (m.version !== 1) return 'bad box version'
  // AES-GCM over a JSON alert of at most a few kilobytes, base64.
  if (typeof m.box !== 'string' || m.box.length < 24 || m.box.length > 8_192 || !/^[A-Za-z0-9+/]+={0,2}$/.test(m.box)) return 'bad box'
  return null
}

/** Kept in step with `PushEnvelope` by hand; `PushTests` checks the Mac's side. */
const PLACEHOLDER = { title: 'Nimlet', body: 'Something needs you' }
const CATEGORIES = ['mice.agent.event', 'mice.agent.approval']

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return json({ error: 'POST only' }, 405)

    // Applied before parsing/authentication to bound scanner traffic. Missing
    // bindings fail closed; deployment must include wrangler.toml's counters.
    const sourceLimit = await enforceLimit(env.SOURCE_PUSH_LIMITER,
      'source:' + (request.headers.get('cf-connecting-ip') ?? 'unknown'))
    if (sourceLimit) return sourceLimit

    // Optional, and worth being honest about what it buys: the Mac app has to
    // carry this secret, so anyone who unpacks the app has it. It is not an
    // authorisation boundary — it keeps random internet scanners from using
    // the endpoint at all, and nothing more. The real limit on abuse is that a
    // push needs a device token, which only a Mac that phone was paired with
    // has, and that an unsealed push says only "Something needs you".
    if (env.RELAY_SECRET) {
      if (request.headers.get('authorization') !== `Bearer ${env.RELAY_SECRET}`) {
        return json({ error: 'no' }, 401)
      }
    }

    let body
    try {
      body = await request.json()
    } catch {
      return json({ error: 'not json' }, 400)
    }

    const { token, sandbox, payload, collapseId, expiration, priority } = body
    if (typeof token !== 'string' || !/^[0-9a-fA-F]{64,200}$/.test(token)) {
      return json({ error: 'bad token' }, 400)
    }
    const problem = validatePayload(payload)
    if (problem) return json({ error: problem }, 400)
    if (collapseId !== undefined && !/^[0-9a-f]{16}$/.test(String(collapseId))) {
      return json({ error: 'bad collapseId' }, 400)
    }
    if (priority !== undefined && priority !== 5 && priority !== 10) return json({ error: 'bad priority' }, 400)

    // Tokens are opaque but identifying. Counter keys retain only their hash;
    // uppercase/lowercase hex forms share the same per-phone budget.
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token.toLowerCase()))
    const key = 'device:' + Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('')
    const deviceLimit = await enforceLimit(env.DEVICE_PUSH_LIMITER, key)
    if (deviceLimit) return deviceLimit

    const headers = {
      authorization: `bearer ${await providerToken(env)}`,
      'apns-topic': env.APNS_TOPIC,
      'apns-push-type': 'alert',
      // 10 is "deliver now". The whole point of this path is a phone that is
      // asleep and an agent that is blocked; there is no such thing as a
      // low-priority one of these.
      'apns-priority': String(priority ?? 10),
      'content-type': 'application/json',
    }
    // Replaces a notification already on the phone instead of stacking behind
    // it — the same rule the on-phone path follows, enforced by Apple.
    if (collapseId) headers['apns-collapse-id'] = String(collapseId).slice(0, 64)
    // A question whose deadline has passed is simply never delivered.
    if (Number.isFinite(expiration)) headers['apns-expiration'] = String(Math.floor(expiration))

    const host = sandbox ? APNS.sandbox : APNS.production
    const response = await fetch(`${host}/3/device/${token}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
    })

    // Passed through rather than flattened, because the two answers the Mac
    // must tell apart both arrive as a 4xx: `BadDeviceToken` means this phone
    // is gone and the Mac should stop pushing to it, while anything else is a
    // problem with this worker that the user cannot fix by re-pairing.
    const reason = response.ok ? null : await response.text().catch(() => null)
    return json({ ok: response.ok, status: response.status, reason }, response.ok ? 200 : 502)
  },
}

// Exported for Relay/worker.test.js, which checks the two pieces most likely to
// be silently wrong: parsing the .p8 Apple hands you, and producing a
// signature APNs will actually accept.
export { providerToken, pemToBytes, base64url, base64urlBytes }

async function enforceLimit(limiter, key) {
  if (!limiter) return json({ error: 'rate limit unavailable' }, 503)
  try {
    const { success } = await limiter.limit({ key })
    if (success) return null
    return new Response(JSON.stringify({ error: 'rate limit exceeded' }), {
      status: 429,
      headers: { 'content-type': 'application/json', 'retry-after': '60' },
    })
  } catch {
    return json({ error: 'rate limit unavailable' }, 503)
  }
}

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function base64url(text) {
  return base64urlBytes(new TextEncoder().encode(text))
}

function base64urlBytes(bytes) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** The .p8 Apple hands you is PKCS#8 PEM. Web Crypto wants the bytes. */
function pemToBytes(pem) {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '')
  const binary = atob(body)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}
