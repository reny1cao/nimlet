import SwiftUI
import AVFoundation
import Speech

/// The two screens before the app is any use, and the only two that exist
/// solely to be read.
///
/// They are here because the alternative is what the app did before: open on a
/// pairing form, ask for the local network in a system alert nobody expected,
/// and ask for the microphone in the middle of the first sentence somebody
/// tried to dictate — losing it. Saying what will be asked for, before it is
/// asked for, is the whole job.

struct Onboarding: View {
    @State private var stage: Stage = .welcome

    private enum Stage { case welcome, permissions }

    let onFinished: () -> Void

    var body: some View {
        Group {
            switch stage {
            case .welcome:
                WelcomeScreen(onSetUp: { stage = .permissions },
                              onSkip: finish)
            case .permissions:
                PermissionsScreen(onContinue: finish)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: stage)
    }

    /// The flag itself belongs to whoever decides what to show — `NimletRemoteApp`
    /// reads it and writes it from this callback. Writing it here as well gave
    /// one persisted value two owners, and this one never read it back.
    private func finish() { onFinished() }
}

// MARK: - Welcome

private struct WelcomeScreen: View {
    let onSetUp: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            Text("Nimlet")
                .font(.largeTitle.weight(.bold))
            Text("A trackpad and a microphone for the coding agents running on your Mac.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 8)
            Spacer()
            // The other half. The invitation to this app arrives before anyone
            // has heard of the companion, and a phone with nothing to find
            // used to sit on "Still looking…" with no hint why.
            VStack(alignment: .leading, spacing: 6) {
                Text("You'll need the free Nimlet companion on your Mac, running in its menu bar, with both devices on the same Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                Link(destination: NimletClient.macDownloadURL) {
                    Label("Get it at nimlet.app/download", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.medium))
                }
            }
            .padding(.bottom, 14)
            // Said before the system asks, not after: an alert you were not
            // expecting is one you deny.
            Text("Setting up asks for the local network, so this phone can find your Mac.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 14)

            Button(action: onSetUp) {
                Text("Set up").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .font(.body.weight(.semibold))

            Button("I've paired before", action: onSkip)
                .frame(maxWidth: .infinity, minHeight: 44)
                .font(.callout)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Permissions

/// What iOS will and will not tell us about a permission.
///
/// Three of the four can be read back. The local network cannot: iOS has no API
/// for its status, so it is inferred from whether discovery has ever returned
/// anything — which is exactly the thing the permission gates.
@MainActor
final class PermissionSummary: ObservableObject {
    enum Status {
        case granted, denied, notAsked, unknown
        /// Motion is not a permission iOS grants or refuses — a gyroscope is
        /// either there or it is not, and there is no API to ask about it.
        /// Labelling that "Allowed" would claim something was decided.
        case present, absent

        var label: String {
            switch self {
            case .granted: return "Allowed"
            case .denied: return "Denied"
            case .notAsked: return "Not yet"
            case .unknown: return "Unknown"
            case .present: return "Available"
            case .absent: return "Unavailable"
            }
        }

        var tint: Color {
            switch self {
            case .granted, .present: return .green
            case .denied: return .orange
            case .notAsked, .unknown, .absent: return .white.opacity(0.45)
            }
        }
    }

    @Published var microphone: Status = .notAsked
    @Published var speech: Status = .notAsked

    func refresh() {
        microphone = {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notAsked
            @unknown default: return .unknown
            }
        }()
        speech = {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notAsked
            @unknown default: return .unknown
            }
        }()
    }
}

private struct PermissionsScreen: View {
    let onContinue: () -> Void
    @EnvironmentObject private var client: NimletClient
    @StateObject private var summary = PermissionSummary()
    @StateObject private var motion = MotionSteering()

    private var networkStatus: PermissionSummary.Status {
        // Seeing any Mac at all is proof the grant went through. Not seeing one
        // is not proof it did not — there may simply be no Mac running Nimlet —
        // so this never claims a denial it cannot know about, except the one
        // iOS reports: the browser parked on a policy error.
        if client.localNetworkDenied { return .denied }
        return client.hosts.isEmpty ? .notAsked : .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions")
                .font(.largeTitle.weight(.bold))
                .padding(.bottom, 18)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                row("Local network", "wifi", networkStatus,
                    detail: networkStatus == .denied
                        ? "Turned off in iOS Settings, so this phone can't find or reach a Mac."
                        : "Finds your Mac. Without it, type its address instead.")
                divider
                row("Microphone", "mic", summary.microphone,
                    detail: "Asked the first time you dictate — by holding a pane's tile, or with the microphone beside the message box.")
                divider
                row("Speech recognition", "waveform", summary.speech,
                    detail: "Uses on-device recognition when available. Fallback recognition may send audio to Apple.")
                divider
                row("Motion", "gyroscope",
                    motion.isAvailable ? .present : .absent,
                    detail: motion.isAvailable
                        ? "Steers the pointer when you hold the Air pill."
                        : "This device reports no gyroscope, so the Air pill won't steer.")
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("You can continue without the microphone and speech — the trackpad, "
                 + "quick replies and approvals all work without them.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 14)

            Spacer()

            if summary.microphone == .denied || summary.speech == .denied || networkStatus == .denied {
                // Once denied, nothing in this app can ask again. The only
                // honest next step is the one place that can change it.
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .font(.callout)
            }

            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .font(.body.weight(.semibold))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            summary.refresh()
            // Browsing is what triggers the local-network prompt, so it starts
            // here — on the screen that just explained why.
            client.startBrowsing()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func row(_ title: String,
                     _ symbol: String,
                     _ status: PermissionSummary.Status,
                     detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // The word, not only the colour.
            Text(status.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(status.tint)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status.label). \(detail)")
    }
}
