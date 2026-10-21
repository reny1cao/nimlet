import Foundation

/// Wire protocol shared verbatim by the macOS host and the iOS remote.
/// Framing: one JSON object per line (UTF-8, `\n` terminated) over TLS/TCP —
/// TLS 1.3 with pinned keys for phones, TLS-PSK for the `nimlet` command-line tool.
public enum NimletProtocol {
    /// Bumped to 25: phones are paired by key only. `RemoteAccessPayload` carries
    /// the trust listeners' addresses and the push key, and nothing for a phone
    /// on the pairing code; the two ends must speak the same version.
    ///
    /// 24: a phone can pair by key instead of by code. The Mac runs a
    /// second listener, advertised as `trustBonjourType`, where both ends
    /// present a certificate and pin the other's key (TLS 1.3, so forward
    /// secrecy), and a phone that has never been there proves it scanned the
    /// Mac's QR code with `pair`. The device id on that listener is the key's
    /// fingerprint, read from the handshake. See `DeviceTrust.swift`.
    ///
    /// 23: the phone can be reached when it is asleep. It
    /// registers an APNs token and the notification rules it wants applied, and
    /// the Mac — which is the end that is awake — runs those rules itself and
    /// pushes what survives them. Everything past the LAN is sealed with the
    /// per-device key from v18, so the relay that holds the APNs credential
    /// carries ciphertext and a device token and learns nothing else. See
    /// `PushEnvelope`.
    ///
    /// 22: the Mac can be heard. A phone opens a third socket with
    /// `listenHello` and the Mac sends its own output mix down it as AAC — so
    /// whatever the Mac is playing, from a video call to an agent's chime,
    /// arrives in your pocket. It is the first thing in this protocol that
    /// carries sound, and the first that keeps working with the app in the
    /// background, which is the whole point: you are not at the desk.
    ///
    /// 21: a scroll says where it is in its life. The phone marks the
    /// finger arriving on the strip, the finger leaving, and the coast that
    /// follows a flick, and the Mac stamps those phases onto the scroll events
    /// it posts — which is the difference between a trackpad and a mouse wheel
    /// as far as every scroll view on the Mac is concerned. Without them an app
    /// cannot rubber-band at the end of a document, cannot tell a gesture from a
    /// notch of a wheel, and treats a continuous flick as a burst of unrelated
    /// ticks.
    ///
    /// 19: the panel stream carries where the Mac's pointer is inside
    /// the window it is mirroring. A mirror zoomed past what it can show at once
    /// follows the cursor with it — there is no gesture spare for panning the
    /// tile, since the pad's one finger is the pointer and its two are the
    /// scroll, and following where the person is already looking is better than
    /// a gesture would have been.
    ///
    /// 20: a minimised window can be opened from the phone. Focusing
    /// one is still refused — raising a window somebody put away because a tap
    /// landed on the wrong card is the mistake that refusal exists to prevent
    /// — so this is a message of its own, sent only when it was asked for.
    /// The panel's state frames say which of them opening would clear.
    ///
    /// 18: the Mac can say where it is reachable from away. It hands
    /// the phone every address worth trying and, once, the 256-bit key that
    /// address is guarded by — so the phone on cellular dials the Mac directly
    /// instead of needing a VPN the user installs on two devices. See
    /// `RemoteAccess`.
    ///
    /// 17: the panel stream carries the window's corner radius. A
    /// window is masked into its rounded shape when it is composited, so the
    /// buffer a stream hands over is square and the phone was drawing four
    /// corners of it that nobody at the Mac can see. The Mac measures the mask
    /// once per window and sends the radius as a fraction of the width.
    ///
    /// 16: the phone can point at what it can see. A touch on the
    /// mirror arrives as a place in the window being mirrored, and the Mac puts
    /// the pointer there — which is the only thing the phone cannot work out
    /// for itself, since it knows the picture and nothing about the display
    /// behind it.
    ///
    /// 15: a target can be pointed at one window rather than at an
    /// app. The phone asks for an app's open windows, gets a card each with a
    /// title and a picture, and picking one raises that exact window, keeps it,
    /// and mirrors it. The promise is the strict part: once a window is pinned,
    /// focus, text and the mirror go to that window or nowhere — a window that
    /// has closed or been minimised is reported, never swapped for its
    /// neighbour.
    ///
    /// 14: the Mac offers its own applications. It ranks what is
    /// installed by how much it is actually used, renders each icon, and sends
    /// the list over — so adding Claude to the dock is tapping its icon rather
    /// than typing `com.anthropic.claudefordesktop` from memory on a phone
    /// keyboard, which is what it was.
    ///
    /// 13: an app's buttons can come from the app. The phone asks for
    /// a bundle id, the Mac walks that app's menu bar with the Accessibility
    /// grant it already holds, and sends back a set built from the keys the app
    /// publishes for itself — which is the only way to be right about an app
    /// whose keys have been rebound, or one nobody ever wrote a set for.
    ///
    /// 12: images.  A batch of attachments arrives on a connection of
    /// its own, announced with `uploadHello` and then framed like the panel
    /// channel — because an image cannot go down the control channel, whose
    /// lines are capped at 1 MiB and whose encoder is shared with the pointer
    /// path. The Mac writes the files and delivers their paths.
    ///
    /// 11 merged with the panel mirror, which adds a second
    /// connection and a host clock on every pong.
    ///
    /// 10 let the phone reorder the target list, which is the
    /// order the dock is drawn in.
    ///
    /// 9 gave a target a shortcut profile, and a key is an
    /// arbitrary chord rather than one of five named keys — because what
    /// belongs on the phone depends on what is listening at the other end.
    ///
    /// 8 named the keys and addressed them to a target, the way text already
    /// was.
    ///
    /// 7 let targets be listed, added, edited and removed from the phone, and
    /// had the Mac say which of them no longer resolve to a live pane.
    ///
    /// 6 added agent approval requests, answered from the phone.
    ///
    /// 5 added delivery receipts, agent events, device approval, per-target
    /// submit policy and dictation vocabulary, and removed `startVoice`.
    public static let version = 28

    public static let bonjourType = "_mice._tcp"
    /// The trust listener's service. Advertised under the same instance name
    /// as `bonjourType`, so a remembered Bonjour host is dialled on either by
    /// changing only the type.
    public static let trustBonjourType = "_nimlet._tcp"
    /// The Mac's key fingerprint, in the trust service's TXT record. Not a
    /// secret, and not trusted either: the phone pins what the QR code said,
    /// and this only lets it skip a Mac that is plainly not that one.
    public static let txtFingerprintKey = "fp"
    /// Bonjour TXT record keys. The version is published here so a client can
    /// tell a mismatch *before* the TLS handshake, where it would read as a
    /// refused key.
    public static let txtVersionKey = "v"
    public static let txtHostKey = "host"

    /// Whether this host can talk to a client claiming `clientVersion`. Both
    /// ends are built from the same tree, so they must agree exactly.
    public static func supports(clientVersion: Int) -> Bool {
        clientVersion == version
    }

    /// The refusal a client on another version receives.
    ///
    /// Kept as one string so the phone can recognise it by prefix whatever the
    /// numbers say; see `ConnectionRejection`.
    public static func versionRefusal(clientVersion: Int) -> String {
        "Nimlet on this phone speaks protocol \(clientVersion), and this Mac speaks \(version). "
            + "Update whichever end is older."
    }
}

// MARK: - Targets

/// Somewhere text can be delivered. "Claude", "Codex", "whatever is focused".
public struct NimletTarget: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Raise a GUI app by bundle identifier, then paste.
        case app
        /// Deliver straight into a tmux pane with `tmux send-keys`. No window focus needed.
        case tmux
        /// Paste into whatever already has keyboard focus.
        case frontmost
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// For `.app`: e.g. `com.anthropic.claudefordesktop`.
    public var bundleID: String?
    public var applicationPath: String?
    public var pinnedAppIdentity: AppInstanceIdentity?
    /// For `.tmux`: a stable pane id such as `%3`.
    ///
    /// Positional specs (`codex:0.1`) are accepted on input and migrated, but
    /// never stored: window and pane indices renumber whenever a pane closes,
    /// and a stale positional target pastes into whatever now occupies the slot
    /// and presses Return on it.
    public var tmuxTarget: String?
    /// Press Return after delivering the text.
    public var submitOnSend: Bool
    /// Hard policy: when false this target may receive text but Nimlet will never
    /// press Return on it, whatever `submitOnSend` or a per-message override
    /// says. The delivery path ends at a shell prompt, so "type it but let me
    /// hit enter myself" has to be expressible and has to win.
    public var allowAutoSubmit: Bool
    /// SF Symbol shown on the phone button.
    public var symbol: String
    /// Which set of shortcuts the phone offers for this target. nil means "work
    /// it out": from the pane's foreground process for a tmux target, and from
    /// the kind for everything else.
    public var profileID: String?
    /// For `.app`: the one window of that app this target is pointed at, as a
    /// `CGWindowID`.
    ///
    /// Nil means "whichever window the app is showing", which is what every app
    /// target used to be — and is still the right answer for an app that only
    /// ever has one. Set, it is a promise that has to be kept exactly: text,
    /// focus and the mirror all go to *that* window or to nothing at all. A
    /// window id is only meaningful while the window exists, so a stale one
    /// resolves to nothing and is reported rather than quietly replaced by a
    /// sibling window the user never chose.
    public var pinnedWindowID: UInt32?
    /// What that window was called when it was picked. Only ever used to
    /// describe it — "Nimlet — the window you picked has closed" is a sentence
    /// that needs a name, and by then the window is gone.
    public var pinnedWindowTitle: String?

    /// Offered by the Mac rather than chosen by the user: a live tmux pane or a
    /// running app that no target points at yet.
    ///
    /// The macOS Dock keeps two lists in one strip — the apps you put there,
    /// and, past a divider, the ones that happen to be running. The second list
    /// is what makes the first one safe to curate: whatever you did not think
    /// to add is still one click away, so the Dock can never be quietly wrong
    /// about what is reachable. Nimlet had only the curated list, seeded once on
    /// a first run and never added to again, so a tmux session started
    /// afterwards was invisible until somebody went to Settings and built it by
    /// hand.
    ///
    /// These are never persisted. They are recomputed from what is live every
    /// time the Mac reports, and the first time one is used it is promoted into
    /// a real target keeping the same id — which is the phone's version of
    /// dragging a running app leftwards out of the Dock's temporary section.
    public var isProvisional: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                kind: Kind,
                bundleID: String? = nil,
                applicationPath: String? = nil,
                pinnedAppIdentity: AppInstanceIdentity? = nil,
                tmuxTarget: String? = nil,
                submitOnSend: Bool = true,
                allowAutoSubmit: Bool = true,
                symbol: String = "square.dashed",
                profileID: String? = nil,
                pinnedWindowID: UInt32? = nil,
                pinnedWindowTitle: String? = nil,
                isProvisional: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundleID = bundleID
        self.applicationPath = applicationPath
        self.pinnedAppIdentity = pinnedAppIdentity
        self.tmuxTarget = tmuxTarget
        self.submitOnSend = submitOnSend
        self.allowAutoSubmit = allowAutoSubmit
        self.symbol = symbol
        self.profileID = profileID
        self.pinnedWindowID = pinnedWindowID
        self.pinnedWindowTitle = pinnedWindowTitle
        self.isProvisional = isProvisional
    }

    /// Whether a fresh target for this app should press Return after pasting.
    ///
    /// A terminal is the one kind of app where Return is not "send" but
    /// "run", and a dictated sentence run as a shell command is the failure
    /// this product must never produce by default. Shell panes in tmux were
    /// already seeded without Return; an app tile for Terminal, iTerm or Warp
    /// was not, so this is the same rule applied to the window. Everywhere a
    /// target is made for a user rather than by them — seeding, the
    /// provisional dock, the phone's picker — goes through here.
    public static func pressesReturnByDefault(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return ShortcutProfiles.guess(forBundleID: bundleID).id != ShortcutProfiles.terminalApp.id
    }

    /// Applies `pressesReturnByDefault` to an app target that was built with
    /// the default policy. Both fields, because `allowAutoSubmit` is the one
    /// that cannot be talked around by a per-message override.
    public mutating func applyDefaultSubmitPolicy() {
        guard kind == .app, !Self.pressesReturnByDefault(bundleID: bundleID) else { return }
        submitOnSend = false
        allowAutoSubmit = false
    }

    /// Decoded field by field with defaults for everything added after v4.
    ///
    /// This is not ceremony: `TargetStore` reseeds from scratch when its saved
    /// JSON fails to decode, so a synthesised `Codable` that chokes on an older
    /// file would silently delete every target the user had configured. Adding a
    /// field must never be able to do that.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Target"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .frontmost
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        applicationPath = try c.decodeIfPresent(String.self, forKey: .applicationPath)
        pinnedAppIdentity = try c.decodeIfPresent(AppInstanceIdentity.self, forKey: .pinnedAppIdentity)
        tmuxTarget = try c.decodeIfPresent(String.self, forKey: .tmuxTarget)
        submitOnSend = try c.decodeIfPresent(Bool.self, forKey: .submitOnSend) ?? true
        allowAutoSubmit = try c.decodeIfPresent(Bool.self, forKey: .allowAutoSubmit) ?? true
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.dashed"
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
        pinnedWindowID = try c.decodeIfPresent(UInt32.self, forKey: .pinnedWindowID)
        pinnedWindowTitle = try c.decodeIfPresent(String.self, forKey: .pinnedWindowTitle)
        // A Mac on an older build sends no such field, and a target that is
        // treated as one the user chose is the safe way to be wrong about this:
        // it stays put rather than vanishing from the dock on the next report.
        isProvisional = try c.decodeIfPresent(Bool.self, forKey: .isProvisional) ?? false
    }

    /// True when `tmuxTarget` is a stable pane id rather than a positional spec.
    public var hasStableTmuxID: Bool {
        guard let tmuxTarget else { return false }
        return tmuxTarget.hasPrefix("%")
    }
}

/// A tmux pane as the phone offers it when a target is being pointed at one.
///
/// The id is what gets stored, because it survives panes opening and closing;
/// the spec and the command are what a person recognises, and neither is
/// stable enough to be saved.
public struct TmuxPane: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var spec: String
    public var command: String
    public var path: String

    public init(id: String, spec: String, command: String, path: String) {
        self.id = id
        self.spec = spec
        self.command = command
        self.path = path
    }

    /// The last two components of the path, which is what tells two checkouts
    /// of the same project apart without spending the whole width on `/Users`.
    public var shortPath: String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

/// An application on the Mac, as the phone is offered it.
///
/// The bundle identifier is the only part that gets stored; everything else is
/// here so the phone can draw the app the way its owner recognises it — its own
/// icon, its own name, and enough of the usage the Mac ranked it by to say why
/// it is near the top.
public struct MacApp: Codable, Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    /// The app's icon as a 128px PNG.
    ///
    /// Optional because a catalogue is sometimes only a ranking — and because
    /// an icon that could not be rendered must cost the app its picture, not
    /// its place in the list.
    public var icon: Data?
    /// What to draw instead, and what the target keeps: a tile has to have
    /// something on it while the icons are in flight, and on the day the phone
    /// is talking to a Mac whose disk no longer has that app on it.
    public var symbol: String
    /// Open right now. Both a ranking signal and something worth showing: the
    /// app you are looking at is usually the one you meant.
    public var isRunning: Bool
    /// Already in the dock. Offering it a second time would let a person make
    /// two targets for one app without noticing.
    public var isAdded: Bool
    /// What the ranking was built from. Carried so the picker can say "used
    /// often" or "3d ago" rather than presenting an order with no account of
    /// itself.
    public var useCount: Int
    public var lastUsedEpochMillis: Int64?

    public var applicationPath: String?
    public var id: String { applicationPath.map { bundleID + "@" + $0 } ?? bundleID }

    public init(bundleID: String,
                name: String,
                icon: Data? = nil,
                symbol: String = "app",
                isRunning: Bool = false,
                isAdded: Bool = false,
                useCount: Int = 0,
                lastUsedEpochMillis: Int64? = nil,
                applicationPath: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.symbol = symbol
        self.isRunning = isRunning
        self.isAdded = isAdded
        self.useCount = useCount
        self.lastUsedEpochMillis = lastUsedEpochMillis
        self.applicationPath = applicationPath
    }

    /// Field by field with a default for each, for the same reason `NimletTarget`
    /// is: one unknown or missing key must not cost the whole catalogue.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try c.decodeIfPresent(Data.self, forKey: .icon)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "app"
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        isAdded = try c.decodeIfPresent(Bool.self, forKey: .isAdded) ?? false
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedEpochMillis = try c.decodeIfPresent(Int64.self, forKey: .lastUsedEpochMillis)
        applicationPath = try c.decodeIfPresent(String.self, forKey: .applicationPath)
    }

    /// The target this app becomes when somebody taps it.
    ///
    /// Built here rather than on the phone so that what the Mac offered and
    /// what it is asked to add cannot drift apart — and `submitOnSend` is true
    /// because an app target ends in a text field, not at a shell prompt.
    public func asTarget() -> NimletTarget {
        NimletTarget(name: name, kind: .app, bundleID: bundleID, applicationPath: applicationPath, symbol: symbol)
    }
}

// MARK: - Messages: phone -> Mac

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

public enum ClickPhase: String, Codable, Sendable {
    case down, up
    /// A complete down+up in one message.
    case click
}

/// Where a scroll is in its life.
///
/// The four states a macOS scroll gesture has, and the Mac needs all four: a
/// scroll view's rubber band starts at `began`, releases at `ended`, and is held
/// open in between, while the coast after a flick is a separate pair so an app
/// can tell movement a finger is making now from movement it made a moment ago.
///
/// An unpaired `began` would leave every scroll view on the Mac believing a
/// finger is still down, so the host closes one out on its own if the phone
/// stops talking mid-gesture.
public enum ScrollGesturePhase: String, Codable, Sendable {
    /// A finger has landed on the strip. The deltas that follow are its.
    case began
    /// It has left, and did not leave fast enough to coast.
    case ended
    /// It left fast enough: the deltas that follow are the coast, and no finger
    /// is down.
    case momentumBegan
    /// The coast has run out.
    case momentumEnded
}

public struct TextPayload: Codable, Sendable {
    public var text: String
    /// nil means "use whatever target is currently selected on the host".
    public var targetID: String?
    /// Overrides the target's own `submitOnSend` when set. Never overrides
    /// `allowAutoSubmit`, which is policy rather than preference.
    public var submit: Bool?

    public init(text: String, targetID: String? = nil, submit: Bool? = nil) {
        self.text = text
        self.targetID = targetID
        self.submit = submit
    }
}

public struct KeyPayload: Codable, Sendable {
    public var chord: KeyChord
    /// Where the key should land. nil means whatever has keyboard focus on the
    /// Mac, which is what every key did before this field existed — and which
    /// is why `escape` could not reach an agent running in a pane that was not
    /// in front.
    public var targetID: String?

    public init(chord: KeyChord, targetID: String? = nil) {
        self.chord = chord
        self.targetID = targetID
    }

    /// Two older shapes still decode. v8 sent one of five names; before that it
    /// was a macOS virtual key code and no target at all. Both keep behaving
    /// exactly as they did.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
        if let chord = try c.decodeIfPresent(KeyChord.self, forKey: .chord) {
            self.chord = chord
            return
        }
        if let named = try c.decodeIfPresent(String.self, forKey: .key) {
            switch named {
            case "enter": chord = KeyChord("enter")
            case "interrupt": chord = KeyChord("c", control: true)
            case "copy": chord = KeyChord("c", command: true)
            case "paste": chord = KeyChord("v", command: true)
            default: chord = KeyChord("escape")
            }
            return
        }
        let legacy = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0x35
        let command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
        let control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        switch (legacy, command, control) {
        case (0x24, _, _): chord = KeyChord("enter")
        case (0x08, true, _): chord = KeyChord("c", command: true)
        case (0x09, true, _): chord = KeyChord("v", command: true)
        case (0x08, _, true): chord = KeyChord("c", control: true)
        default: chord = KeyChord("escape")
        }
    }

    /// Only the two current fields go out; the older ones are read-only, and
    /// are the reason this is written by hand rather than synthesised.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chord, forKey: .chord)
        try c.encodeIfPresent(targetID, forKey: .targetID)
    }

    private enum CodingKeys: String, CodingKey {
        case chord, targetID, key, keyCode, command, control
    }
}

public struct HelloPayload: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// Stable per-installation id, generated once and kept. The host approves
    /// and revokes *devices*, and it cannot do either if every reconnection
    /// looks like a stranger.
    public var deviceID: String

    public init(protocolVersion: Int = NimletProtocol.version,
                deviceName: String,
                deviceID: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

/// Reported by a client that watches an agent — today the `nimlet` CLI, driven
/// from the user's own hook.
public struct AgentEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case done, waiting, failed
    }

    public var targetID: String
    public var kind: Kind
    /// Milliseconds since 1970. An explicit integer rather than a `Date`, so the
    /// two ends cannot disagree via a `JSONEncoder.dateEncodingStrategy`.
    public var atEpochMillis: Int64
    public var note: String?
    /// Who reported it, for when `targetID` is not a target either end knows:
    /// an agent in the Claude desktop app, in ChatGPT's Codex, or in a pane
    /// nobody made a tile for. Its "waiting for you" still has to reach the
    /// phone, and "Codex" is a better name for it than an id.
    public var sourceName: String?

    public init(targetID: String, kind: Kind, atEpochMillis: Int64, note: String? = nil, sourceName: String? = nil) {
        self.targetID = targetID
        self.kind = kind
        self.atEpochMillis = atEpochMillis
        self.note = note
        self.sourceName = sourceName
    }
}

public enum ClientMessage: Codable, Sendable {
    case hello(HelloPayload)
    /// Relative pointer delta in host points, already accelerated by the phone.
    case move(dx: Double, dy: Double)
    /// Pixel-unit scroll delta. Positive dy scrolls content down.
    case scroll(dx: Double, dy: Double)
    /// Where the scroll those deltas belong to is in its life.
    ///
    /// Sent as markers around the deltas rather than as a field on each one, so
    /// the hot path stays the line it has always been and an older Mac that has
    /// never heard of phases still gets every delta. The Mac holds the current
    /// phase and stamps it onto the events it posts.
    case scrollPhase(ScrollGesturePhase)
    /// Put the pointer here in the window being mirrored, as fractions of that
    /// window: (0, 0) is its top-left corner and (1, 1) its bottom-right.
    ///
    /// Everything else about the pointer is relative, because a trackpad has
    /// nowhere to point *at*. A mirror does: the finger is on the thing it
    /// means, and turning that into a nudge of so many points would be throwing
    /// away the one piece of information the gesture had.
    ///
    /// In the window's own coordinates rather than the screen's. The phone
    /// knows the picture it was sent and nothing about where that window is,
    /// how many displays there are or how they are arranged; the Mac knows all
    /// three and is already tracking the window frame to capture it.
    ///
    /// `generation` is which window the phone was *showing* when the finger
    /// came down — the generation stamped on the frame it put on the glass.
    /// With it the Mac resolves the touch against that window or refuses it,
    /// exactly, the moment the picture changes; without it (an older phone)
    /// the Mac falls back to estimating when the phone caught up.
    case pointAtPanel(x: Double, y: Double, generation: Int? = nil)
    /// Reshape the window being mirrored to this width-over-height.
    ///
    /// Sent while somebody drags the seam between the phone's picture and its
    /// pad. The band can be any height they like; the window was one shape,
    /// and without this a taller band is the same picture with black above and
    /// below it. Only the shape is sent — the Mac decides the size, because it
    /// is the end that knows which screen the window is on and how much of it
    /// there is.
    ///
    /// No version bump: a Mac that has never heard of it drops the line, which
    /// leaves the band letterboxed and nothing else wrong.
    case reshapePanel(aspect: Double)
    case click(button: MouseButton, phase: ClickPhase, clickCount: Int)
    case text(TextPayload)
    /// Bring a target to the front and make it the active one.
    case focus(targetID: String)
    case key(KeyPayload)
    /// Ask for the dictation vocabulary for a target, so on-device transcription
    /// can be biased toward that project's identifiers.
    case requestVocabulary(targetID: String)
    /// Ask the host to add a target. The host owns the target list and rewrites
    /// it whenever anything changes, so a client that edited the saved copy
    /// directly would have its change silently overwritten by the running app.
    case addTarget(NimletTarget)
    /// Change one that already exists, by id. The whole target is sent rather
    /// than a set of fields: the Mac replaces its copy, which is the only way
    /// two phones editing the same target cannot interleave into a third thing
    /// neither of them asked for.
    case updateTarget(NimletTarget)
    /// Several at once, added under exactly the rules one is. Sent when a
    /// person ticks four apps in the picker and taps Add: as four `addTarget`s
    /// it was four round trips and four toasts saying much the same thing, and
    /// a partial failure in the middle of them had no way to be described.
    case addTargets([NimletTarget])
    case removeTarget(id: String)
    /// The whole list in its new order. Sent as an order rather than as a move,
    /// so two phones dragging at once converge on one of the two orders instead
    /// of on a third that neither of them arranged.
    case reorderTargets(ids: [String])
    /// Ask for the tmux panes running right now, so a target can be pointed at
    /// one without typing a pane id from memory.
    case requestPanes
    /// Ask which applications this Mac has, ranked by how much they are used,
    /// with their icons. `refresh` rebuilds the Mac's cache rather than reading
    /// it, for somebody who has just installed something and is looking for it.
    case requestApps(refresh: Bool)
    case requestAppDirectory(refresh: Bool)
    case requestAppState
    case requestAppWindows(AppInstanceIdentity)
    case appCommand(AppCommand)
    /// Ask which windows that target's app has open right now, with a preview
    /// of each. Answered with `windows`.
    ///
    /// Windows, not documents: what the window server has open, which is not an
    /// app's own list of conversations or tabs and is never presented as one.
    case requestWindows(targetID: String)
    /// Point this target at exactly that window — raise it, keep it, and mirror
    /// it. `windowID` nil lets the target go back to following whichever window
    /// the app puts in front.
    ///
    /// Refused rather than approximated: if that window has closed or is
    /// minimised, the Mac says so and changes nothing. Silently landing on a
    /// sibling window is how a message meant for one conversation is typed into
    /// another.
    case focusWindow(targetID: String, windowID: UInt32?)
    /// Bring a minimised window back, then point this target at it.
    ///
    /// Separate from `focusWindow` on purpose. Focusing refuses a minimised
    /// window — raising one would un-minimise something the user deliberately
    /// put away, and it is not a refusal worth losing. This is the other
    /// answer to the same situation, and it exists so that un-minimising is
    /// always something that was *asked for* rather than something that
    /// happened because a tap landed on the wrong card.
    ///
    /// `windowID` nil means the window this target is already pinned to, which
    /// is the case the mirror runs into: the pane you were watching got
    /// minimised, and the only thing you want is it back.
    case openWindow(targetID: String, windowID: UInt32?)
    /// Ask for the icons of apps the phone already has targets for. The dock
    /// draws an app as its own icon, and after a reinstall or a cache purge the
    /// phone holds targets whose pictures it has never seen.
    case requestAppIcons(bundleIDs: [String])
    /// Ask what that app's own menu bar says its keys are. `refresh` skips the
    /// Mac's cache, for the case the user has just rebound something and wants
    /// the row to catch up without relaunching anything.
    case requestMenu(bundleID: String, refresh: Bool)
    /// An agent changed state. Sent by the CLI from a user-installed hook.
    case agentEvent(AgentEvent)
    /// An agent is asking permission and is blocked until it is answered. Sent
    /// by the CLI from a user-installed hook; the host fans it out to the
    /// phones and sends the resolution back to whoever asked.
    case requestApproval(ApprovalRequest)
    /// Somebody answered. Sent by a phone, or by a second CLI on the Mac.
    ///
    /// `reason` reaches the agent with the denial. Without one it asks for the
    /// same thing again a minute later, having learned nothing from being told
    /// no — which is how a permission prompt becomes a thing people tap through.
    ///
    /// `answers` is the reply to a question, one per question; `alwaysAllow`
    /// takes the agent's own "don't ask again"; `handBack` leaves it to the
    /// agent's own prompt. All three optional, so a Mac or phone a release
    /// behind still reads the message — and reads it as the plain decision.
    case approvalDecision(id: String, decision: ApprovalDecision, reason: String?,
                          answers: [String]? = nil, alwaysAllow: Bool? = nil, handBack: Bool? = nil)
    /// Asks for whatever is currently pending — how a phone that was asleep,
    /// backgrounded or freshly reconnected catches up on a blocked agent.
    case requestPendingApprovals
    /// Sent on a second connection to turn it into a one-way panel stream.
    case viewHello(ViewHelloPayload)
    /// Sent on a connection of its own to turn it into an attachment upload: the
    /// manifest first, and then one binary frame per image once the Mac has said
    /// it is ready. Nothing else ever travels on that socket, which is what lets
    /// its framing change underneath.
    case uploadHello(AttachmentManifest)
    /// Sent on a connection of its own: give me a picture of that target's
    /// screen. The Mac answers with one binary frame and closes.
    case stillHello(StillRequest)
    /// Sent on a connection of its own to turn it into the Mac's audio, coming
    /// this way. Re-sent to pause and resume without giving the socket up —
    /// stopping the capture on the Mac costs a second to start again, and
    /// letting go of the microphone should not cost a second of silence.
    case listenHello(ListenHelloPayload)
    /// On the panel socket: every video frame up to and including this
    /// sequence has been read. Sent once per batch read, from the network
    /// queue, so it measures the link rather than the main thread.
    case viewAck(sequence: Int)
    /// Phase 0 of the direct path (`DirectProbe`): here is a UDP address this
    /// phone will punch from. Sent inside the session, so a relay carrying it
    /// never learns either end's address.
    case directOffer(DirectCandidate)
    /// What the probe measured, for the Mac's log.
    case directReport(DirectProbeReport)
    /// Asks the Mac for a UDP pair at the connect relay, to carry the session
    /// over KCP instead of TCP while it is on the relay (`RelayDatagramGrant`).
    case relayTunnelRequest
    case ping(nonce: UInt64)
    /// Ask for the away addresses again. Sent on connecting, so a phone that
    /// has been reinstalled — or one whose key the Mac has since rotated —
    /// catches up without waiting for the address to happen to change.
    case requestRemoteAccess
    /// Here is my APNs token and here is what I want to be woken for.
    ///
    /// Sent on connecting and whenever a notification setting changes. Both
    /// halves matter: without the token the Mac cannot reach a sleeping phone
    /// at all, and without the rules it would have to guess what is worth
    /// waking somebody for — so a target muted on the phone would be one whose
    /// push arrives and is ignored, having already lit the screen.
    ///
    /// A token of nil means stop.
    case registerPush(PushRegistration)
    /// I scanned your QR code: the proof, bound to this TLS session and to the
    /// key I just authenticated with (`PairingProof`). The only thing a
    /// connection from an unknown key may say, and only while the Mac has an
    /// invitation open.
    case pair(PairRequest)
}

/// What a phone sends to be let in by key the first time.
public struct PairRequest: Codable, Sendable, Equatable {
    public var proof: Data
    public var deviceName: String

    public init(proof: Data, deviceName: String) {
        self.proof = proof
        self.deviceName = deviceName
    }
}

/// The Mac's answer to `pair`.
public struct PairResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

extension ClientMessage {
    /// The device id this message claims, if it is one of the five that do.
    public var claimedDeviceID: String? {
        switch self {
        case .hello(let hello): return hello.deviceID
        case .viewHello(let hello): return hello.deviceID
        case .listenHello(let hello): return hello.deviceID
        case .uploadHello(let manifest): return manifest.deviceID
        case .stillHello(let request): return request.deviceID
        default: return nil
        }
    }

    /// The same message, naming `deviceID` wherever it names a device.
    ///
    /// The trust listener knows which device a socket is from the key it
    /// proved in the handshake, so whatever a hello *says* is replaced with
    /// that before anything reads it. A phone cannot be anybody but itself.
    public func claiming(deviceID: String) -> ClientMessage {
        switch self {
        case .hello(var hello):
            hello.deviceID = deviceID
            return .hello(hello)
        case .viewHello(var hello):
            hello.deviceID = deviceID
            return .viewHello(hello)
        case .listenHello(var hello):
            hello.deviceID = deviceID
            return .listenHello(hello)
        case .uploadHello(var manifest):
            manifest.deviceID = deviceID
            return .uploadHello(manifest)
        case .stillHello(var request):
            request.deviceID = deviceID
            return .stillHello(request)
        default:
            return self
        }
    }
}

// MARK: - Messages: Mac -> phone

public struct HostStatus: Codable, Sendable, Equatable {
    public var hostName: String
    public var protocolVersion: Int
    /// CGEvent injection silently no-ops without this. The single most common failure.
    public var accessibilityGranted: Bool
    public var injectionPaused: Bool
    public var activeTargetID: String?
    /// False while the Mac is still waiting for the user to approve this device.
    /// The connection is up and the handshake succeeded; nothing will be
    /// injected until someone says yes on the Mac.
    public var deviceApproved: Bool
    /// True when tmux is installed, so the phone can explain why a first run has
    /// no pane targets instead of silently offering only app targets.
    public var tmuxAvailable: Bool
    /// A second TCC grant, entirely separate from Accessibility, and without it
    /// window mirroring produces nothing. Same failure shape, same treatment.
    public var screenRecordingGranted: Bool
    /// Targets whose tmux pane no longer exists. They are kept rather than
    /// deleted — the pane is usually one `tmux new-session` away — but a target
    /// that will swallow everything sent to it has to look different from one
    /// that works.
    public var unresolvedTargetIDs: [String]
    /// Whether this Mac has somewhere to send a push, so the phone can say
    /// whether notifications survive the app being frozen or stop there. See
    /// `PushSender`.
    public var appManagementVersion: Int?
    public var pushRelayConfigured: Bool
    /// How long an agent's question waits for an answer, as set in Settings →
    /// Agents. Read by `nimlet` when a hook asks; nil from a Mac that predates
    /// the setting.
    public var agentWaitSeconds: Int?

    public init(hostName: String,
                protocolVersion: Int = NimletProtocol.version,
                accessibilityGranted: Bool,
                injectionPaused: Bool,
                activeTargetID: String?,
                deviceApproved: Bool = false,
                tmuxAvailable: Bool = false,
                screenRecordingGranted: Bool = false,
                unresolvedTargetIDs: [String] = [],
                pushRelayConfigured: Bool = false,
                appManagementVersion: Int? = nil,
                agentWaitSeconds: Int? = nil) {
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.accessibilityGranted = accessibilityGranted
        self.injectionPaused = injectionPaused
        self.activeTargetID = activeTargetID
        self.deviceApproved = deviceApproved
        self.tmuxAvailable = tmuxAvailable
        self.screenRecordingGranted = screenRecordingGranted
        self.unresolvedTargetIDs = unresolvedTargetIDs
        self.pushRelayConfigured = pushRelayConfigured
        self.appManagementVersion = appManagementVersion
        self.agentWaitSeconds = agentWaitSeconds
    }
}

/// What actually happened to a delivery, echoed back so the phone can confirm
/// it with a distinct haptic. A blind input surface gives the user no way to
/// tell a failed delivery from a slow agent, and unattributable failures are
/// what destroy trust in it.
public struct DeliveryReceipt: Codable, Sendable, Equatable {
    public var ok: Bool
    public var targetID: String?
    public var targetName: String
    public var characters: Int
    /// Whether Return was actually pressed — not whether it was requested.
    public var submitted: Bool
    public var message: String

    public init(ok: Bool, targetID: String?, targetName: String,
                characters: Int, submitted: Bool, message: String) {
        self.ok = ok
        self.targetID = targetID
        self.targetName = targetName
        self.characters = characters
        self.submitted = submitted
        self.message = message
    }
}

/// The buttons an app publishes for itself, read off its own menu bar.
///
/// A refusal travels the same way an answer does, and says which one it is.
/// "That app is not running" and "Nimlet cannot see its menus" want different
/// things from the user, and a phone that is only ever told nothing arrived
/// cannot tell them apart — so `note` is carried even when `profile` is nil.
public struct MenuProfilePayload: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case read
        /// The app is not running, so it has no menu bar to read.
        case notRunning
        /// Its menus could not be read at all — no Accessibility grant, or an
        /// app that publishes none.
        case unreadable
        /// They were read and had too little in them to be worth showing.
        case nothingUseful
    }

    public var bundleID: String
    public var outcome: Outcome
    /// Present only when `outcome` is `read`.
    public var profile: ShortcutProfile?
    /// One line for the settings screen, whatever the outcome.
    public var note: String

    public init(bundleID: String, outcome: Outcome, profile: ShortcutProfile? = nil, note: String) {
        self.bundleID = bundleID
        self.outcome = outcome
        self.profile = profile
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        // Read as a string and mapped, rather than decoded as the enum: an
        // outcome a newer Mac has and this build has not would otherwise throw,
        // and a throw here loses the whole message — including the note that
        // would have explained it.
        let rawOutcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        outcome = rawOutcome.flatMap(Outcome.init(rawValue:)) ?? .unreadable
        profile = try c.decodeIfPresent(ShortcutProfile.self, forKey: .profile)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// One window of one application, as the phone is offered it.
///
/// A window rather than a document: this is what the window server has open
/// right now, which is not the same list as an app's own — Claude's
/// conversations, a browser's tabs — and must never be presented as if it were.
/// If it is not a window you could click on the Mac, it is not in here.
public struct MacWindow: Codable, Sendable, Hashable, Identifiable {
    /// The `CGWindowID`. Unique while the window lives and never reissued to a
    /// different window of the same app, which is the whole reason the pin is
    /// this and not a title.
    public var id: UInt32
    /// The window's own title. Empty for the apps that publish none, which the
    /// phone draws as the app's name and an index rather than as a blank card.
    public var title: String
    public var appName: String
    /// Minimised to the Dock. It still exists, so it is still offered — but
    /// nothing can be delivered to it and it cannot be photographed.
    public var isMinimized: Bool
    /// Drawable right now. False for a minimised window and for one on another
    /// Space.
    public var isOnScreen: Bool
    /// The window this app would bring forward on its own.
    public var isFrontmost: Bool
    /// Currently pinned by the target this list was asked for.
    public var isPinned: Bool
    public var width: Int
    public var height: Int
    /// A JPEG of the window, where one could be taken. Nil for a minimised
    /// window, and on a Mac that has not granted Screen Recording.
    public var preview: Data?
    /// Whether this window can actually be raised — which needs Accessibility
    /// and an unambiguous match between what the window server lists and what
    /// the app publishes. A window that cannot be raised is still worth showing
    /// and still says so, because the alternative was raising a different one.
    public var canClose: Bool
    public var canRaise: Bool

    public init(id: UInt32,
                title: String,
                appName: String,
                isMinimized: Bool = false,
                isOnScreen: Bool = true,
                isFrontmost: Bool = false,
                isPinned: Bool = false,
                width: Int = 0,
                height: Int = 0,
                preview: Data? = nil,
                canRaise: Bool = true,
                canClose: Bool = false) {
        self.id = id
        self.title = title
        self.appName = appName
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
        self.isFrontmost = isFrontmost
        self.isPinned = isPinned
        self.width = width
        self.height = height
        self.preview = preview
        self.canRaise = canRaise
        self.canClose = canClose
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UInt32.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        isMinimized = try c.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false
        isOnScreen = try c.decodeIfPresent(Bool.self, forKey: .isOnScreen) ?? true
        isFrontmost = try c.decodeIfPresent(Bool.self, forKey: .isFrontmost) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        preview = try c.decodeIfPresent(Data.self, forKey: .preview)
        canRaise = try c.decodeIfPresent(Bool.self, forKey: .canRaise) ?? true
        canClose = try c.decodeIfPresent(Bool.self, forKey: .canClose) ?? false
    }

    /// What to call it on a card. An untitled window is not nameless — it is
    /// the app's, and saying so beats an empty rectangle.
    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
    }
}

/// The windows one app has open, chunked because the previews are pictures.
public struct WindowListPayload: Codable, Sendable, Equatable {
    /// Which target asked. A phone may have two app targets for one app, and
    /// the shelf that opened belongs to one of them.
    public var appIdentity: AppInstanceIdentity?
    public var targetID: String
    public var windows: [MacWindow]
    /// Why the list is short or empty, where there is a reason worth reading:
    /// the app is not running, Accessibility is not granted, Screen Recording
    /// is off so there are no previews. Nil when the list simply is the answer.
    public var note: String?
    public var sequence: Int
    public var isFinal: Bool

    public init(targetID: String,
                windows: [MacWindow],
                note: String? = nil,
                sequence: Int = 0,
                isFinal: Bool = true,
                appIdentity: AppInstanceIdentity? = nil) {
        self.targetID = targetID
        self.appIdentity = appIdentity
        self.windows = windows
        self.note = note
        self.sequence = sequence
        self.isFinal = isFinal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID) ?? ""
        appIdentity = try c.decodeIfPresent(AppInstanceIdentity.self, forKey: .appIdentity)
        windows = try c.decodeIfPresent([MacWindow].self, forKey: .windows) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    }

    private static func wireCost(_ window: MacWindow) -> Int {
        ((window.preview?.count ?? 0) * 4) / 3 + 256
    }

    /// The same split the app catalogue does, for the same reason: a preview is
    /// tens of kilobytes and the framer drops an overlong line whole.
    public static func chunked(_ windows: [MacWindow],
                               targetID: String,
                               note: String? = nil,
                               budget: Int = 256 << 10,
                               appIdentity: AppInstanceIdentity? = nil) -> [WindowListPayload] {
        var chunks: [[MacWindow]] = []
        var current: [MacWindow] = []
        var spent = 0
        for window in windows {
            var window = window
            if wireCost(window) > budget { window.preview = nil }
            let cost = wireCost(window)
            if !current.isEmpty, spent + cost > budget {
                chunks.append(current)
                current = []
                spent = 0
            }
            current.append(window)
            spent += cost
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { index, windows in
            WindowListPayload(targetID: targetID, windows: windows,
                              // The note rides the first chunk only, so a phone
                              // folding chunks together shows it once.
                              note: index == 0 ? note : nil,
                              sequence: index, isFinal: index == chunks.count - 1,
                              appIdentity: appIdentity)
        }
    }
}

/// The Mac's applications, chunked.
///
/// Chunked for the reason the vocabulary is: an icon is about fifteen kilobytes
/// of PNG and a catalogue is a couple of dozen apps, so the whole answer is
/// comfortably past the framer's one-megabyte line and would be dropped in
/// silence at exactly the moment it became useful.
public struct AppCatalogPayload: Codable, Sendable, Equatable {
    public enum Purpose: String, Codable, Sendable {
        /// Apps worth adding, ranked. Replaces whatever the phone was showing.
        case suggestions
        /// Icons for apps the phone already has targets for. Folded into its
        /// cache, and never allowed to change the list it is offering.
        case icons
    }

    public var purpose: Purpose
    public var apps: [MacApp]
    /// 0-based chunk index.
    public var sequence: Int
    /// True on the last chunk of a set — including on the empty one sent when
    /// there is nothing to say, which is what takes the spinner down.
    public var isFinal: Bool

    public init(purpose: Purpose, apps: [MacApp], sequence: Int, isFinal: Bool) {
        self.purpose = purpose
        self.apps = apps
        self.sequence = sequence
        self.isFinal = isFinal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Read as a string and mapped, for the reason `MenuProfilePayload` does
        // it: a purpose a newer Mac has and this build has not would otherwise
        // throw, and a throw loses the whole line.
        let raw = try c.decodeIfPresent(String.self, forKey: .purpose)
        purpose = raw.flatMap(Purpose.init(rawValue:)) ?? .suggestions
        apps = try c.decodeIfPresent([MacApp].self, forKey: .apps) ?? []
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    }

    /// Roughly what an app costs on the wire: its icon, base64'd, plus a little
    /// for the rest of the object.
    private static func wireCost(_ app: MacApp) -> Int {
        ((app.icon?.count ?? 0) * 4) / 3 + 256
    }

    /// Splits a catalogue into lines the framer will actually deliver.
    ///
    /// `budget` is a quarter of the framer's limit rather than all of it: the
    /// estimate above is an estimate, and a chunk that turns out too big is not
    /// a truncated list but a missing one.
    ///
    /// An app whose icon alone would not fit is sent without it. It keeps its
    /// place, its name and its glyph, which is the whole of what it needs to be
    /// tappable.
    public static func chunked(_ apps: [MacApp],
                               purpose: Purpose,
                               budget: Int = 256 << 10) -> [AppCatalogPayload] {
        var chunks: [[MacApp]] = []
        var current: [MacApp] = []
        var spent = 0
        for app in apps {
            var app = app
            if wireCost(app) > budget { app.icon = nil }
            let cost = wireCost(app)
            if !current.isEmpty, spent + cost > budget {
                chunks.append(current)
                current = []
                spent = 0
            }
            current.append(app)
            spent += cost
        }
        // The empty chunk matters: it is how "no apps" is told apart from "not
        // answered yet" on the phone.
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { index, apps in
            AppCatalogPayload(purpose: purpose, apps: apps,
                              sequence: index, isFinal: index == chunks.count - 1)
        }
    }
}

/// Dictation vocabulary for one target, chunked.
///
/// A mid-size repository's symbol list does not fit in one line: `LineFramer`
/// caps a line at 1 MiB, so a single payload would be silently dropped at
/// exactly the moment the feature becomes useful.
public struct VocabularyPayload: Codable, Sendable, Equatable {
    public var targetID: String
    public var terms: [String]
    /// 0-based chunk index.
    public var sequence: Int
    /// True on the last chunk of a set.
    public var isFinal: Bool

    public init(targetID: String, terms: [String], sequence: Int, isFinal: Bool) {
        self.targetID = targetID
        self.terms = terms
        self.sequence = sequence
        self.isFinal = isFinal
    }
}

public enum HostMessage: Codable, Sendable {
    case appState(AppRuntimeSnapshot)
    case appCommandResult(AppCommandResult)
    case welcome(status: HostStatus, targets: [NimletTarget])
    case status(HostStatus)
    case targets([NimletTarget])
    /// Human-readable confirmation to echo on the phone, e.g. "Sent 14 words to Claude".
    case toast(String)
    case error(String)
    /// The outcome of a text delivery, for haptic confirmation.
    case delivered(DeliveryReceipt)
    /// An agent changed state, fanned out from whichever client reported it.
    case agentEvent(AgentEvent)
    case vocabulary(VocabularyPayload)
    /// An agent is blocked, waiting for a decision.
    case approvalRequest(ApprovalRequest)
    /// That request is over, however it ended. Sent to the asker so it can stop
    /// blocking, and fanned out so a second phone takes the card down rather
    /// than answering a question that has already been answered.
    case approvalResolved(ApprovalResolution)
    /// The whole pending set, in answer to `requestPendingApprovals`. Sent as
    /// one message rather than as a burst of `approvalRequest`s, so a phone can
    /// replace its list instead of merging into a stale one.
    case pendingApprovals([ApprovalRequest])
    /// The live tmux panes, in answer to `requestPanes`.
    case panes([TmuxPane])
    /// One app's open windows, in answer to `requestWindows`. Chunked, because
    /// every card carries a picture.
    case windows(WindowListPayload)
    /// This Mac's applications, in answer to `requestApps` or
    /// `requestAppIcons`. Chunked — see `AppCatalogPayload`.
    case apps(AppCatalogPayload)
    /// What an app's menu bar publishes, in answer to `requestMenu`.
    case menu(MenuProfilePayload)
    /// Go ahead and send the attachments. Sent on the upload socket in answer to
    /// `uploadHello`, and worth the round trip twice over: the phone learns that
    /// the batch was refused — unknown target, unapproved device, a count the
    /// Mac will not accept — before it spends a second pushing megabytes at it,
    /// and the Mac can switch that socket over to binary framing knowing no
    /// image bytes are already in flight behind the manifest.
    case uploadReady(batchID: String)
    /// `hostTime` is the host's monotonic clock at the moment it replied. With
    /// the round trip it pins the offset between the two clocks, which is what
    /// turns a frame's capture stamp into a real glass-to-glass latency instead
    /// of two unrelated uptimes.
    case pong(nonce: UInt64, hostTime: UInt64)
    /// Where this Mac can be reached from away, and the key for reaching it.
    ///
    /// Pushed whenever it changes rather than only in answer to a request: a
    /// home IP address moves when the ISP decides it should, and the phone that
    /// needs the new one is by definition not the one that can ask for it. A
    /// phone that is on the Mac's network gets corrected without anybody doing
    /// anything, which is where phones spend most of their time.
    case remoteAccess(RemoteAccessPayload)
    /// The Mac's side of `directOffer`: where it punches from, or why it
    /// cannot (no global IPv6 on a physical interface).
    case directAnswer(DirectCandidate?, note: String?)
    /// The Mac's side of `relayTunnelRequest`: the relay's UDP address and the
    /// pair's token, or why there is none (an older relay, no relay).
    case relayTunnel(RelayDatagramGrant?, note: String?)
    /// The answer to `pair`. On success the connection carries on as an
    /// approved one and the phone sends `hello` next; on failure it is closed.
    case pairResult(PairResult)
}

// MARK: - Line framing

/// Accumulates bytes and yields complete newline-delimited JSON payloads.
public struct LineFramer {
    private var buffer = Data()
    /// Guards against a peer that never sends a newline.
    private let maxLineBytes: Int
    /// Set after an overlong line. While true, bytes are dropped up to and
    /// including the next newline.
    private var resynchronising = false
    /// Number of overlong lines discarded. Surfaced so an oversized payload is
    /// a diagnosable event rather than a message that silently never arrives.
    public private(set) var droppedLines = 0

    public init(maxLineBytes: Int = 1 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Hands back whatever is buffered and forgets it.
    ///
    /// For a socket whose framing changes: an upload connection is
    /// newline-framed for exactly one line — the manifest — and
    /// length-prefixed for everything after it. The handshake means the phone
    /// sends no image bytes until the Mac has replied, so this is normally
    /// empty; draining it anyway is what keeps a client that ignored the
    /// handshake from stranding its first frame in a framer nobody reads again.
    public mutating func drain() -> Data {
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []

        while true {
            if resynchronising {
                // Throw away the tail of the overlong line, then carry on with
                // whatever follows it. The previous behaviour — dropping the
                // whole buffer — also destroyed every intact message that
                // happened to arrive in the same packet.
                guard let idx = buffer.firstIndex(of: 0x0A) else {
                    buffer.removeAll(keepingCapacity: true)
                    break
                }
                buffer = Data(buffer[buffer.index(after: idx)...])
                resynchronising = false
                continue
            }

            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<idx]
                buffer = Data(buffer[buffer.index(after: idx)...])
                if !line.isEmpty { lines.append(Data(line)) }
                continue
            }

            if buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                resynchronising = true
                droppedLines += 1
                continue
            }
            break
        }
        return lines
    }
}

public enum NimletCoder {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    /// `JSONEncoder` is a class and is not documented as safe for concurrent
    /// use. The host encodes from its network queue, its injection queue and
    /// main; one uncontended lock acquisition is far cheaper than the
    /// alternative of allocating a coder per pointer packet at 120 Hz.
    private static let lock = NSLock()

    /// Encodes a message as a single `\n`-terminated line.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encode(value)
        data.append(0x0A)
        return data
    }

    /// The same encoder without the terminator, for the panel channel, whose
    /// frames are length-prefixed rather than newline-delimited. Public so that
    /// channel does not need its own coder — one lock, one configuration.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.decode(type, from: data)
    }
}
