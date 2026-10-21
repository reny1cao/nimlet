# The push relay

The only part of Nimlet that does not run on your own machines, and the smallest
it could be made.

## Why it has to exist

A local notification needs the app to be running. iOS freezes a backgrounded
app after about twenty-five seconds — `NimletClient.backgroundGrace` — and a
frozen app is not reading its socket. From then on nothing the Mac sends
arrives anywhere. Reaching that phone means APNs, because APNs is delivered by
the system to a device rather than to a process.

A push has to be signed with the APNs key, and that key belongs to the Apple
Developer team that owns the bundle id. Not to you, and not to your Mac.
Shipping it inside the Mac app would hand every copy the ability to push to
every other user's phone, so one thing has to hold it and sign on request.

This is that thing.

## What it can see

An opaque device token, a length, and a clock.

The notification itself was built and sealed on the Mac with the 256-bit key
Nimlet already issues per device at pairing (`RemoteAccess`, `AwayKeys` — one per
phone, in the Keychain at both ends, handed over on your own LAN and never sent
anywhere else). What the relay forwards is AES-GCM ciphertext. A notification
service extension on the phone opens it a moment before it is shown. See
`Shared/PushEnvelope.swift`.

So: not which target, not which agent, not what it said, not what command it
wanted to run. Not a promise about the relay's good behaviour — a statement
about what it is given. `PushTests.testNothingReadableTravels` asserts it.

The two things it does see, honestly: the device token, which is unavoidable
because APNs is addressed by it, and the notification *category* — one bit
saying "this one has Approve and Deny on it" — which is in the clear because a
category that arrives only from the extension may be resolved too late for the
buttons.

## Deploying it

Five one-time steps. The first two need your Apple Developer account; nothing
about them is specific to this relay.

**1. Make an APNs key.** In the developer portal, Certificates, Identifiers &
Profiles → Keys → new key, tick *Apple Push Notifications service (APNs)*.
Download the `.p8` — you get one chance — and note the 10-character Key ID and
your Team ID.

**2. Turn on Push Notifications for the App ID** `com.renyicao.mice.remote`.
Xcode's automatic signing will usually do this for you the first time it builds
the app with `Signing/NimletRemote.entitlements` in place; if it refuses, tick it
in the portal by hand and let Xcode refresh the profile.

**3. Deploy.**

```bash
cd Relay
npm install -g wrangler
wrangler secret put APNS_KEY      # paste the whole .p8, BEGIN/END lines and all
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID
wrangler secret put RELAY_SECRET  # optional; see below
wrangler deploy
```

It has no database, KV or Durable Objects. The deployment includes two
Cloudflare Rate Limiting bindings for the counters described in step 5. Existing
APNs secrets are retained by a normal Worker update; do not print or replace
them just to deploy code.

**4. Point the Mac at it.**

```bash
defaults write com.renyicao.mice.host mice.push.relay https://mice-push.<you>.workers.dev
```

The secret, if you set one, goes into Settings → Notifications in the Mac
app, which keeps it in the Keychain. (A `mice.push.secret` preference written
by an older build is moved there the first time the app reads it.)

**5. Verify rate limits.** `wrangler.toml` declares the bindings and the Worker
enforces them: 30 pushes per device per minute, and 300 requests per source IP
per minute. Device counter keys are SHA-256 hashes of normalized APNs tokens.
Missing or unavailable counters return 503; an exhausted budget returns 429
with `Retry-After: 60`, before contacting APNs. Use Wrangler 4.36.0 or newer.

These counters are per Cloudflare location and approximate, rather than a strict
global quota. Do not assume a zone WAF rule protects a `workers.dev` URL. Verify
the deployed bindings and a 429 response on the actual Worker endpoint.
See [Cloudflare's Rate Limiting binding documentation](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).

There is no address compiled into a plain checkout. Nimlet talks to your Mac
and nowhere else until somebody says otherwise on purpose, and this is the
one path that leaves the building. A build made with `MICE_PUSH_RELAY_URL`
set carries the address, and Settings says so.

## About `RELAY_SECRET`

It keeps random internet scanners from using the endpoint. It is **not** an
authorisation boundary: the Mac has to carry it, so anyone who unpacks the Mac
app has it too.

What actually limits abuse is that a push needs a device token — which only a
Mac that phone was paired with has — and that a push nobody can seal says only
"Nimlet · Something needs you". Two things make that second part true rather
than hoped for. The worker forwards only a payload shaped exactly as the Mac
writes one (`validatePayload`): the fixed placeholder text, one of the two
categories, a hashed thread id, a sealed box, and nothing else — anything
carrying its own words or its own buttons gets a 400. And the phone's
extension shows the placeholder, without buttons or identifiers, for any
push whose box it cannot open. Someone who has a token can be a nuisance.
They cannot read anything, cannot write anything, and cannot make a phone
approve a command: the Approve button opens the app and the decision travels
over the real connection.

The nuisance is bounded by the rate limit in step 5 above, which is part of
deploying this, not an afterthought.

## What it does not do

**Retract.** APNs has no way to take back a notification already sitting on a
sleeping phone. On the LAN path Nimlet takes banners down as they stop being true
— a finished agent removes its own "waiting for you", an answered approval
takes its buttons with it — and over push it cannot. Two things soften it:
`apns-collapse-id`, so a target's newer alert replaces its older one rather than
stacking, and `apns-expiration` set to an approval's own deadline, so a question
the clock has already answered is never delivered at all.

**Queue.** If the relay is down the push is lost, not retried. The agent's state
is still on the Mac, and the dock shows it with an age attached the moment the
app opens.
