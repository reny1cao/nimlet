# Privacy

Nimlet does not require a Nimlet account or include an app analytics or
crash-reporting service. Control messages, text, images, audio and screen
previews travel between your phone and your Mac over encrypted connections.
They can travel directly, through a separately configured VPN, or through
Nimlet's optional connect relay when Away access is enabled. The connect relay
forwards the encrypted stream; it cannot decrypt your work content. Optional
push notifications use a separate notification relay and Apple Push
Notification service.

Some supporting services can contact other machines: Apple's speech recognition
fallback may process audio, speech language assets may be downloaded from Apple,
and optional away access may query a public STUN server. The applications you
send content to may also store or upload it under their own privacy policies.
The sections below explain these boundaries.

## Your voice

The primary speech path uses iOS 26's `SpeechAnalyzer` and `SpeechTranscriber`
on the phone. Nimlet does not save voice recordings or send them to your Mac.
Only the resulting text is sent to the Mac. iOS may download language assets
to support on-device recognition.

Sound travels the other way when you switch listening on — see "Hearing your
Mac" below. That stream pauses while you dictate; it never carries the phone's
microphone to the Mac.

There is one exception, and it is real. When `SpeechTranscriber` is unavailable,
Nimlet falls back to `SFSpeechRecognizer` and asks for on-device recognition
(`requiresOnDeviceRecognition`) whenever the device reports that it supports it
for your locale. On a device that does **not** support on-device recognition for
that locale, the fallback runs as a server request, which means the audio goes
to Apple. Permission and setup text disclose this possible fallback, but Nimlet
does not show a per-recording indicator of whether Apple is processing it.
If you require strictly on-device processing, use typed input instead of
dictation until that recognition path can be confirmed for your device and language.

## Hearing your Mac

Tapping the headphones on the phone asks the Mac to send its audio, and this is
the only thing in Nimlet that carries sound over the network. What it is, exactly:

**It is the whole output mix, not one app.** ScreenCaptureKit is asked for the
display's audio, which is everything your Mac is playing — a call, a video, a
notification chime, all of it together. It is not possible to hear one app and
not another, and Nimlet does not try to filter: a mix you cannot reason about
would be worse than one you can.

**Your Mac's own microphone is never part of it.** The capture is of what is
being *played*, not of the room. Nimlet never asks for microphone access on the
Mac and could not record the room if it wanted to. But the people on a call are
being played through your speakers, and so are their voices — which is the real
reason to think about who is holding the phone.

**Nothing is captured while nobody is listening.** The capture starts when a
phone switches listening on and stops when the last one switches it off or
disconnects. Off is the default, on every phone, every time the app starts.

**It uses the Screen Recording grant**, because that is what ScreenCaptureKit
is. macOS therefore shows its screen-recording indicator while a phone is
listening — the same indicator as the window mirror, for the same reason. Nimlet
asks the stream for two pixels of picture and throws them away; only the audio
is sent. If you would rather the Mac never offer this at all, **Let phones
listen** in the menu bar turns it off, and a phone that asks anyway is told so
rather than left with silence.

**It is not recorded.** The audio is encoded as AAC, sent over the same TLS
connection as everything else, played on the phone and discarded. Neither end
writes it to disk, and there is no buffer to scroll back through.

**It plays with the app in the background.** This is the one feature that does —
the whole point is that you are not at the desk — so the iOS app declares the
`audio` background mode and registers as what's playing, which is what puts a
pause button on your lock screen. Nothing else about Nimlet runs off screen.

## Being reachable from away

Switching on **Reachable on cellular** in the menu bar enables additional
connection paths. It is off by default.

**A configured connect relay can carry encrypted traffic.** The distributed
Mac companion includes the relay address and its public-key fingerprint. A
custom relay can be configured instead. The Mac registers only while Away
access is enabled and a trusted phone exists. The relay observes connection
IP addresses, a public-key-derived routing identifier, timing and traffic
volume. It keeps active routes and bounded authentication/rate-limit state in
memory. It does not receive the paired private keys or decrypt the phone-to-Mac
TLS stream. The Mac also verifies the connect relay's public key. Turning Away
access off stops that Mac's relay registration. The relay's hosting provider
may process network metadata and operational logs under its own policies.

**Your Mac asks your router for a way in.** Those requests — PCP, NAT-PMP and
UPnP — go to your own router on your own network. They say "please forward TCP
port 61423 to this Mac", they are the same requests a games console or a
BitTorrent client makes, and they leave nothing behind: the mapping is a lease
that expires within the hour, and Nimlet deletes it when you switch away access
off.

**Your Mac may ask a STUN server what its public address is.** This happens only
while away access is on, when your router would not tell Nimlet the answer itself.
Each request contains a STUN header and twelve random bytes. Nimlet may try
another configured server if a request fails. It sends no device name, hostname,
persistent identifier or work content in that request. The server does see your
public IP address and replies with the address it saw the
packet come from, which it learned by receiving the packet, which is true of
every packet that leaves your house.

The default servers are Cloudflare's and Google's public STUN endpoints. If you
would rather they were neither:

```bash
defaults write com.renyicao.mice.host mice.stunServers -array "stun.example.com:3478"
defaults write com.renyicao.mice.host mice.stunServers -array   # or none at all
```

With none at all, away access still works on any router that reports its own
external address, which is most of them.

Your Mac sends connection candidates to its paired phones over their existing
connection. Those phones store the candidates for reconnection. There is no
public directory for browsing users' Macs. The optional relay holds an active
registration for routing to a participating Mac; this is separate from a
public directory.

## Your text

Dictated and typed text travels from the phone to the Mac over TLS, keyed by
the pairing code on the LAN or a per-device key for away access. Nimlet does not
write delivered text to its persistent delivery log. The selected application
or agent may store it, upload it, or write it to its own history.

**Text for app and frontmost targets can pass through the macOS general pasteboard.** Long text is delivered by
putting it on the pasteboard and synthesising ⌘V, because typing it character by
character is slow and some applications drop characters when synthesis outruns
their input handling. The previous pasteboard contents are put back about a
third of a second later.

During that window the text is on the system pasteboard, which means:

- any other application running on your Mac can read it; and
- if Handoff is on, **Universal Clipboard can sync it to your iPhone, iPad and
  other Macs** signed into the same Apple Account.

`tmux` targets use direct pane delivery and do not use the pasteboard. They
do pass through a named tmux buffer (`nimlet`) for the instant between
loading it and pasting it into the pane, and the buffer is deleted on either
outcome — so a delivery that failed does not leave the text readable with
`tmux show-buffer`.
With away access enabled, the direct phone-to-Mac connection can cross the
internet. What macOS then does with the pasteboard depends on your Handoff
setting, and if you
dictate something you would not want appearing on another device, turn Handoff
off in System Settings → General → AirDrop & Handoff.

## Your images

An image you attach to a message is resized on the phone, sent to the Mac over
the same TLS connection's key on a socket of its own, and **written to a file on
the Mac** — `~/Library/Application Support/Nimlet/inbox/`, created mode 0700 with
each file mode 0600. That is not a transport detail: a `tmux` target is sent the
file's *path*, because a pane cannot be handed bytes, so the file has to outlive
the delivery for the agent to be able to open it at all.

Unlike text, therefore, images are stored. Two things bound that:

- anything in the inbox older than a week is deleted on the next upload, and the
  folder is capped at 512 MB, oldest first; and
- the folder is yours — delete it, or anything in it, whenever you like. Nimlet
  makes a new one.

Nimlet sends the image to your Mac; the application or agent you select may then
process or upload it under its own policies. The phone never names the file:
every name is `nimlet-<date>-<n>.<ext>`, chosen on the Mac.

A screenshot you annotate is one of these images, with one extra step before it:
the Mac photographs the target's window — or the display the pointer is on, for a
pane, which is every window on that display — and sends it to the phone so you
can draw on it. An `app` or `frontmost` target whose window cannot be found is
refused rather than photographed as a whole display. That picture crosses the
connection in both directions and is not kept on the Mac by this capture step;
what is kept is the flattened
result, in the inbox, like any other attachment.

**For `app` and `frontmost` targets the image passes through the pasteboard**,
exactly as text does and with the same consequences — an app's composer takes
pictures, not paths, so it is pasted. `tmux` targets do not touch the
pasteboard; they get the path.

## What is stored, and where

On the Mac, in `~/Library/Preferences/com.renyicao.mice.host.plist`:

- the pairing code;
- your configured targets (names, bundle identifiers, tmux pane ids);
- the list of devices you have approved and the list you have rejected, each
  with the device's name and when it was last seen.

Also on the Mac, in `~/Library/Application Support/Nimlet/`:

- `deliveries.log`, an append-only line per delivery — timestamp, whether it was
  delivered or refused, the target's name, how many characters it was, and
  whether Return was pressed. **Not the text.** It exists so you can answer
  "did Nimlet press Return in that pane at 14:02?" without keeping a copy of
  everything you have ever dictated. It is created mode 0600. Delete it whenever
  you like; Nimlet makes a new one.
- `targets-<timestamp>.json`, written only if your saved target list ever fails
  to load. It is a copy of the unreadable file, kept so a bad upgrade cannot
  silently delete the targets you configured.
- `inbox/`, the images you have sent from the phone. See **Your images** above:
  this is the one thing Nimlet keeps a copy of, because the copy *is* what gets
  delivered.

On the phone, in the app's own `UserDefaults`: the pairing code, the Macs it has
seen, your quick replies, your pointer and Air pill preferences, and the target
list as the Mac last described it, so that opening the app draws the dock rather
than an empty screen while it reconnects. That list is what the dock is drawn
from and nothing more — the names, symbols and bundle ids of the tiles, plus the
title of a window a target has been pinned to. The app icons behind the tiles are
cached as files in the app's own `Caches` directory, where the system may reclaim
them at any time.

If you use the `nimlet` command-line tool, it keeps its own copy of the pairing
code in `~/.config/nimlet/config.json`, created mode 0600.

No transcript, no delivered text and no pointer history is kept in any of these;
attached images are the exception, and are covered above.
Away-access keys are stored in the Keychain on both devices. Revoke a phone
from the Mac before removing the apps to invalidate its access. Removing an
app does not guarantee that all preferences, Keychain entries or Mac support
files are erased. Mac preferences, the `Application Support` folder and the
CLI's config file may remain and can be removed separately when no longer needed.

## Logs

Both apps log to the unified system log under the subsystem
`com.renyicao.mice`, which you can read with `make logs`. The host logs
connection events, target names, pointer rates and delivery outcomes — not the
text that was delivered. Window titles, device names, the addresses of your
Mac and your phones, and your Mac's public address are logged as private,
which the system log shows as `<private>` to anything but a live `log stream`
on the machine itself.

**Copy diagnostics** in the menu puts the last ten minutes of that log on
the clipboard, with versions, permissions and connection state in front of
it, so it can be pasted into a bug report. The private fields above come out
redacted; the pairing code, delivered text and addresses are not in it at
all. The clipboard item is marked transient, so clipboard managers do not
keep it and Universal Clipboard does not carry it to your other devices.

The phone logs the same kind of thing — what the engine did, how long the audio
was, how many characters came back — and never the transcript itself, on either
the `SpeechAnalyzer` path or the `SFSpeechRecognizer` fallback. Listening logs
the format, the buffer depth and the number of dropouts, under the category
`listen`; none of that describes what was playing.

## Permissions, and why each one exists

| Where | Permission | What it is actually for |
|---|---|---|
| Mac | Accessibility | Posting the keyboard and mouse events. Without it Nimlet silently does nothing. |
| Mac | Local network | Accepting the connection from your phone. |
| Mac | Screen Recording | Mirroring a window into the phone's panel, taking the screenshot you draw on, and — the same grant, because ScreenCaptureKit is also how audio is captured — sending the Mac's output to a phone that has asked to listen. Asked for the first time one of those actually happens, not at launch. |
| Phone | Microphone | Capturing hold-to-talk audio for transcription, with possible Apple service fallback. |
| Phone | Speech recognition | Running that transcription. |
| Phone | Motion | Steering the pointer while the Air pill is held. |
| Phone | Local network | Finding your Mac over Bonjour. |
| Phone | Camera | Photographing something on your desk to send. Only if you tap Camera; picking an existing photo goes through the system picker, which hands over the one picture you chose without the app ever seeing your library. |

The Mac app asks for nothing else. In particular it does not request microphone
access — the only audio it ever captures is what it is *playing*, through the
Screen Recording grant above, and it cannot hear the room — and it does not
request permission to send Apple Events, because it never sends any.

## Public beta access

During the public beta, all features are available without a purchase. The
beta provides the same full access to every tester. Purchase controls
and prices are hidden. The iPhone app uses Apple's TestFlight receipt or
verified sandbox app transaction to identify the opted-in beta build. This
check stays on the phone; no transaction or receipt is sent to us or to a
server we run. There is no Nimlet account.

Beta access is temporary. Pricing and early-bird terms for the future App
Store release will be announced later. Apple handles TestFlight under its
own privacy policy.

## Nimlet Pro purchases

Nimlet Pro is optional and sold through the App Store, as a monthly or annual
subscription that starts with a two-week free trial, or as a one-time Lifetime
purchase. Apple handles payment, the trial, renewal, cancellation, offer codes
and refunds; Nimlet never sees card details. The iPhone app asks StoreKit on
the phone whether this Apple Account owns Pro, checks Apple's signature on the
answer, and keeps nothing of its own about it. No transaction is sent to us or to any server we run, and there
is no Nimlet account. Apple processes purchase information under its own
privacy policy.

## Checking for updates

The Mac companion is not distributed through an app store, so it has no one to
tell it a newer build exists. About every six hours, and once half a minute
after launch, it fetches one small file — `https://nimlet.app/releases/latest.json`
— naming the current build, and shows a line in its menu when that is newer
than the running copy. Nothing is downloaded or installed by itself.

The request carries no identifier of any kind: no device id, no pairing code,
no account, no cookies. It is the request a browser would make opening that
address, and the server sees what any web server sees — an IP address, a time,
and a `User-Agent` of `Nimlet/<version> (macOS)`. To switch it off:

```
defaults write com.renyicao.mice.host mice.updates.check -bool NO
```

The iPhone app makes no such request; it is updated through TestFlight or the
App Store.

## What an approval banner shows

When an agent asks permission and the phone is asleep, the banner names the
agent and what kind of thing it wants to do — "claude · Run a command". It
does not show the command itself unless you switch on **Show the command in
the banner** under Notifications. The command is the most sensitive thing
this app could put on a lock screen — paths, tokens, repository names — and a
lock screen is read by whoever is looking at the phone. With the switch on,
the first line or two of the command is in the banner; iOS's own "Show
Previews: When Unlocked" setting still hides it until the phone is unlocked.

## Push notifications and VPN routes

A relay address may be built into a release of the Mac companion, or set in its
Settings → Notifications; with neither, nothing leaves the Mac on this path.
When configured, the Mac sends the phone's APNs token and an encrypted notification envelope to the notification relay; the relay forwards it to Apple. The relay and Apple can observe routing metadata and delivery timing, but the application encrypts the notification content for the paired phone. Notification rules and device registration are stored on the Mac. Revoking a phone removes its push registration. Push delivery does not carry remote-control traffic.

The Mac shares active Tailscale interface addresses with its paired phones over their existing TLS session. Both devices must be connected to the same permitted VPN network to use those addresses. Tailscale supplies the encrypted VPN connection and may relay it according to its own service and privacy policies. Nimlet itself does not run a control relay.
