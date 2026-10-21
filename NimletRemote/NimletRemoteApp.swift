import SwiftUI

/// Only for the two callbacks SwiftUI has no equivalent of.
///
/// A device token arrives at `UIApplicationDelegate` and nowhere else — there
/// is no `onReceive` for it, no environment value, no async sequence. So there
/// is an app delegate, it is eleven lines long, and it forwards.
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in AgentAlerts.shared.absorb(deviceToken: token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AgentAlerts.shared.pushRegistrationFailed(error) }
    }
}

@main
struct NimletRemoteApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var client = NimletClient()
    @StateObject private var pro = ProStore.shared
    @StateObject private var voice = VoiceCapture()
    @Environment(\.scenePhase) private var scenePhase
    /// Written by `Onboarding` when it finishes, read here so the app does not
    /// build the whole operation surface behind a screen nobody has passed yet.
    @AppStorage("mice.onboarded") private var onboarded = false
    /// Owned here, not by a screen: the panel keeps streaming while you move the
    /// tile, pop it out and put it back, and one connection serves both sizes.
    @StateObject private var panel = PanelClient()
    /// Owned here for a stronger version of the same reason: listening outlives
    /// every screen in the app, including the app being on screen at all.
    @StateObject private var listen = ListenClient()

    private var pairingTitle: String {
        client.pendingPairing.map { "Pair with “\($0.invitation.name)”?" } ?? "Pair with this Mac?"
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    ContentView()
                } else {
                    Onboarding {
                        onboarded = true
                        // "I've paired before" skips the permissions screen,
                        // which is where browsing normally starts.
                        client.startBrowsing()
                    }
                }
            }
                .environmentObject(client)
                .environmentObject(voice)
                .environmentObject(panel)
                .environmentObject(listen)
                .preferredColorScheme(.dark)
                .onAppear {
                    Instrumentation.logger = remoteLog
                    Haptics.prepare()
                    // Before anything can arrive, and before the first view
                    // that could be deep-linked into has appeared: tapping a
                    // notification is one of the ways this app gets launched,
                    // and the tap is delivered whether or not anybody is ready
                    // for it.
                    AgentAlerts.shared.prime()
                    AgentAlerts.shared.onIntent = handle(_:)
                    // A token, or a change to what this phone wants to be woken
                    // for. Either way the Mac is the end that will act on it.
                    AgentAlerts.shared.onRegistrationChanged = client.sendPushRegistration
                    // The local-network alert is triggered by browsing, and
                    // the welcome screen promises to explain it before it is
                    // asked. So until that screen has been passed, browsing
                    // waits for the permissions screen to start it.
                    if !onboarded { client.browsingAllowed = false }
                    // Same path as coming back from the background, because a
                    // cold launch is not guaranteed to produce a scenePhase
                    // change to hang the first redial on.
                    client.enterForeground()
                    updateIdleTimer()
                }
                // The Mac's QR code, scanned with the Camera. Pairing is a
                // reason to be past the welcome screen: the person has
                // already done the thing it was going to explain.
                .onOpenURL { url in
                    guard PairingInvitation(url: url) != nil else { return }
                    client.acceptInvitation(url)
                }
                // Asked, every time. The link can come from anywhere, and the
                // one fact that makes it safe — that it came off this person's
                // own Mac a moment ago — is one only they know.
                .alert(pairingTitle,
                       isPresented: Binding(get: { client.pendingPairing != nil },
                                            set: { if !$0 { client.cancelPairing() } }),
                       presenting: client.pendingPairing) { _ in
                    Button("Pair") {
                        if !onboarded { onboarded = true }
                        client.browsingAllowed = true
                        client.confirmPairing()
                    }
                    Button("Cancel", role: .cancel) { client.cancelPairing() }
                } message: { pending in
                    Text((pending.replacesPin
                          ? "This replaces the Mac this phone already paired with under that name. "
                          : "")
                         + "Only continue if you just scanned this code on your own Mac's screen. Its key: \(pending.invitation.host.shortCode).")
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        client.enterBackground()
                    case .active:
                        // First, so that the refresh `enterForeground` kicks
                        // off cannot post a banner for a card that is about to
                        // be on screen anyway.
                        AgentAlerts.shared.becameActive()
                        client.enterForeground()
                        Task { await pro.refresh() }
                    default:
                        break
                    }
                    updateIdleTimer()
                }
                .onChange(of: client.state.isConnected) { _, _ in
                    updateIdleTimer()
                }
                // Dictation and listening cannot both have the room. Held here
                // rather than at each of the three places a recording can start,
                // because the one that matters most is the fourth: the ninety-
                // second cap, which ends a recording without anybody letting go
                // of anything.
                .onChange(of: listen.message) { _, message in
                    if let message { client.note(message) }
                }
                .onChange(of: pro.hasPro) { _, hasPro in
                    guard !hasPro else { return }
                    panel.stop()
                    listen.turnOff()
                    Task { await voice.cancel() }
                }
                .onChange(of: voice.isRecording) { _, _ in holdListening() }
                .onChange(of: voice.isPreparing) { _, _ in holdListening() }
                // The mirror holds the picture back to meet the sound, and this
                // is the one number it needs to do it. Wired here rather than by
                // either client reaching for the other: they are useful
                // separately — a mirror with no audio, audio with no mirror —
                // and this is the only place that knows both are on.
                .onChange(of: listen.playbackDelayMillis, initial: true) { _, delay in
                    panel.setAudioDelay(millis: delay)
                }
        }
    }

    /// What a tapped notification asked for.
    ///
    /// Held here rather than in `AgentAlerts` because this is the only place
    /// that has both the client and the screen — and because a notification
    /// tap can land before `ContentView` exists, which is why the alerts
    /// object queues intents until this closure is set rather than firing them
    /// into whatever happens to be listening.
    private func handle(_ intent: AgentAlerts.Intent) {
        switch intent {
        case .openTarget(let id):
            // "Waiting for you" about a target that has a question or a
            // permission prompt open: the tap was for that, so show it.
            if let waiting = client.pendingApproval(for: id) {
                client.approvalRequestID = waiting.id
                client.wantsApprovals = true
            } else {
                client.focus(id)
            }
        case .openApprovals(let requestID):
            client.approvalRequestID = requestID
            client.wantsApprovals = true
        case .decide(let requestID, let decision):
            // Answered from the banner, without the app being opened. `decide`
            // already knows what to do with no connection, and for a denial
            // that is the right answer anyway: an unanswered request expires
            // into one.
            client.decide(requestID, decision, reason: "Answered from a notification")
        }
    }

    /// A trackpad that sleeps mid-gesture is worse than no trackpad — but this
    /// was set unconditionally for the whole session, so the screen also stayed
    /// lit while the app sat on the pairing screen doing nothing, which is how
    /// a phone ends the afternoon hot and flat.
    ///
    /// Listening deliberately does *not* keep the screen awake. It is the one
    /// thing here that is better with the phone locked and in a pocket, and a
    /// screen held on for it would be the same flat battery by another route.
    /// Silence from the Mac while the microphone is open.
    ///
    /// Two reasons, and the second is the one that would have been a bug report.
    /// The obvious one is echo: the speaker is a few inches from the microphone,
    /// so whatever the Mac is playing would be transcribed and pasted into
    /// somebody's prompt. The other is that dictation needs `.playAndRecord` and
    /// listening wants `.playback`, and the two categories cannot both be in
    /// force — so one of them has to stand down, and it is not the one the user
    /// is holding a button for.
    ///
    /// From `isPreparing` as well as `isRecording`, so the hold reaches the Mac
    /// while permissions and language assets are still being sorted out — which
    /// is a comfortable head start on the microphone actually opening.
    private func holdListening() {
        listen.hold(voice.isRecording || voice.isPreparing)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase != .background && client.state.isConnected
    }
}
