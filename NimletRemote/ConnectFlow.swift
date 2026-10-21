import SwiftUI

/// Everything between opening the app and being able to use it: finding a Mac
/// this phone has paired with, or saying how to pair with one, and explaining
/// what went wrong when neither works.
struct ConnectFlow: View {
    @EnvironmentObject private var client: NimletClient
    @State private var troubleShown = false
    @State private var pairing: PairingPrompt?

    var body: some View {
        Group {
            if let failure = client.failure, failure.kind != .unreachable {
                ConnectionFailureScreen(failure: failure, onPickAnother: client.disconnect,
                                        onPair: { pairing = PairingPrompt(hostName: $0) })
            } else if client.retryingSince != nil, !client.state.isConnected {
                ReconnectingScreen(onTrouble: { troubleShown = true }, onPickAnother: client.disconnect)
            } else {
                DiscoverScreen(onPair: { pairing = PairingPrompt(hostName: $0) })
            }
        }
        .sheet(isPresented: $troubleShown) { TroubleScreen() }
        .sheet(item: $pairing) { PairingSheet(hostName: $0.hostName) }
    }
}

/// Which Mac the pairing sheet is for, if the person came from one.
private struct PairingPrompt: Identifiable {
    let hostName: String?
    var id: String { hostName ?? "" }
}

private struct ConnectionFailureScreen: View {
    let failure: NimletClient.Failure
    let onPickAnother: () -> Void
    let onPair: (String?) -> Void
    @EnvironmentObject private var client: NimletClient

    private var title: String {
        switch failure.kind {
        case .revoked: return "This phone was revoked"
        case .versionMismatch: return phoneIsTheOldEnd ? "Update Nimlet on this phone" : "Update Nimlet on your Mac"
        case .notPaired: return "Pair this phone again"
        case .unreachable: return "Can't reach your Mac"
        }
    }

    /// Every refusal that blames the phone says "on this phone"; the ones that
    /// blame the Mac do not. See `NimletClient.versionMismatch(for:)`.
    private var phoneIsTheOldEnd: Bool {
        failure.message.localizedCaseInsensitiveContains("on this phone")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.orange)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text(failure.message).foregroundStyle(.secondary)
            if failure.kind == .revoked {
                Text("Open Nimlet on \(failure.hostName). Under Revoked devices, choose Approve again for this phone, then retry here.")
                Text(client.deviceName.isEmpty ? client.defaultDeviceName : client.deviceName)
                    .font(.headline)
            }
            if failure.kind == .notPaired {
                Text("On \(failure.hostName), open the Nimlet menu and choose Pair a Phone, then scan the code it shows. A new or restored iPhone always pairs again: pairing stays with the phone, not your Apple Account.")
            }
            if failure.kind == .versionMismatch {
                // Which end to update is in the message; where to get it is
                // not, and the Mac companion is not in any store.
                if phoneIsTheOldEnd {
                    Text("Update Nimlet on this phone from TestFlight or the App Store, then try again.")
                        .font(.callout)
                } else {
                    Text("Download the newer Mac companion, install it over the old one, then try again.")
                        .font(.callout)
                    Link(destination: NimletClient.macDownloadURL) {
                        Label("Get the Mac update at nimlet.app", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
            if failure.kind == .notPaired {
                // Pairing again is the way out of this one, so it is the big
                // button; trying again only helps a phone the Mac is about to
                // approve again.
                Button { onPair(failure.hostName) } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Try again") { client.retry() }
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button("Try again") { client.retry() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            // Not for a version mismatch: an update fixes that, and forgetting
            // would make the person pair again for nothing.
            if failure.kind != .versionMismatch, let host = client.failedHost {
                Button("Forget \(host.name)", role: .destructive) {
                    client.disconnect()
                    client.forget(host)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button("Choose a different Mac", action: onPickAnother)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(24)
    }
}

// MARK: - Choose your Mac

private struct DiscoverScreen: View {
    let onPair: (String?) -> Void
    @EnvironmentObject private var client: NimletClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose your Mac")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)

                if needsPairingAgain {
                    // A new iPhone set up from the old one's backup: the Macs
                    // came with it and the key did not. Said once, above them,
                    // rather than on every row.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("This iPhone needs to pair again", systemImage: "iphone")
                            .font(.caption.weight(.semibold))
                        Text("Pairing stays with each phone, not your Apple Account, so a new or restored iPhone starts unpaired. Tap your Mac to pair it again. It takes one scan.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }

                ForEach(client.hosts) { host in
                    if client.hasCredential(for: host.remembered) {
                        pairedRow(host.remembered, icon: "desktopcomputer", detail: nil) { client.connect(to: host) }
                    } else {
                        unpairedRow(host.remembered, again: isRemembered(host.remembered))
                    }
                }

                ForEach(client.rememberedHosts) { host in
                    // Only the ones Bonjour is not already offering, so a Mac
                    // in the room is never listed twice.
                    if !client.hosts.contains(where: { $0.remembered.id == host.id }) {
                        if client.hasCredential(for: host) {
                            pairedRow(host, icon: "clock.arrow.circlepath", detail: "Paired") { client.connect(to: host) }
                        } else {
                            unpairedRow(host, again: true)
                        }
                    }
                }

                // Only while there is nothing to show. With a Mac on the list,
                // a spinner beside it read as that Mac being waited for, when
                // what it needed was a tap.
                if client.hosts.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs on this network…")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                }

                // For a Mac that is not on this network to be found, and for
                // anybody who knows the code is what they need.
                Button { onPair(nil) } label: {
                    Label("Pair a Mac", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                if client.localNetworkDenied {
                    // The one "still looking" that no amount of looking fixes.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("iOS is not letting Nimlet use the local network", systemImage: "wifi.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("Without it this phone cannot find or reach a Mac. Turn it on under Settings → Apps → Nimlet → Local Network, then come back.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .font(.callout)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                } else if client.hosts.isEmpty, client.rememberedHosts.isEmpty, waitedAWhile {
                    // Nothing found and nothing remembered: this phone has never
                    // met a Mac. The likeliest reason by far is that the other
                    // half was never installed — the invitation to this app
                    // arrives before anyone has heard of the companion.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No Mac yet?", systemImage: "desktopcomputer")
                            .font(.caption.weight(.semibold))
                        Text("Nimlet needs its free companion running on your Mac. Install it from nimlet.app/download, open it — it lives in the menu bar — and keep both devices on the same Wi-Fi. This screen finds it by itself.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Link(destination: NimletClient.macDownloadURL) {
                            Label("Get the Mac companion", systemImage: "arrow.down.circle")
                                .font(.callout)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                // Why a Mac this phone has reached from a café before is not
                // being reached now. Without it the screen says "still looking"
                // at a problem that is at the other end and nothing to do with
                // looking — and the one that matters, a carrier-grade NAT on the
                // Mac's own line, cannot be fixed by waiting or by retrying.
                if let why = awayProblem {
                    Label(why, systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.9))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .task {
            try? await Task.sleep(for: .seconds(6))
            waitedAWhile = true
        }
    }

    /// Six seconds of nothing before the "no Mac yet?" card: a Mac on the same
    /// Wi-Fi is found in under one, and the card is for the phone that has
    /// nothing to find.
    @State private var waitedAWhile = false

    /// What the Mac last said about being reachable from away, and only when it
    /// is worth saying: on its own network this screen finds it in a moment, and
    /// an explanation of a path nobody is using is noise.
    private var awayProblem: String? {
        guard client.hosts.isEmpty else { return nil }
        guard let host = client.rememberedHosts.first else { return nil }
        return PhoneTrust.unavailable(forHost: host.id)
    }

    /// Restored from another phone's backup, as far as this phone can tell:
    /// it remembers a Mac it holds no key for.
    private var needsPairingAgain: Bool {
        client.rememberedHosts.contains { !client.hasCredential(for: $0) }
    }

    private func isRemembered(_ host: NimletClient.RememberedHost) -> Bool {
        client.rememberedHosts.contains { $0.id == host.id }
    }

    /// A Mac this phone can dial: tap to connect, and a menu for the two
    /// things that are not connecting. Forgetting used to be offered only for
    /// a Mac that was out of sight, so the one in the room could never be
    /// let go of.
    private func pairedRow(_ host: NimletClient.RememberedHost, icon: String, detail: String?,
                           connect: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: connect) {
                row(icon: icon, title: host.name, detail: detail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(host.name)

            Menu {
                Button { onPair(host.name) } label: {
                    Label("Pair Again…", systemImage: "qrcode.viewfinder")
                }
                Button(role: .destructive) { client.forget(host) } label: {
                    Label("Forget This Mac", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More for \(host.name)")
        }
    }

    /// A Mac this phone holds no key for. It used to be drawn dimmed with
    /// nothing to tap; pairing is the one thing to do with it, so tapping it
    /// does that.
    private func unpairedRow(_ host: NimletClient.RememberedHost, again: Bool) -> some View {
        HStack(spacing: 6) {
            Button { onPair(host.name) } label: {
                row(icon: "desktopcomputer", title: host.name,
                    detail: again ? "Needs to pair again" : "Not paired with this phone", action: "Pair")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(host.name)
            .accessibilityHint("Shows how to pair this phone with it")

            if again {
                Button { client.forget(host) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forget \(host.name)")
            }
        }
    }

    private func row(icon: String, title: String, detail: String?, action: String? = nil) -> some View {
        HStack {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
            if let action {
                Text(action)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            } else {
                Image(systemName: "chevron.right").font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

// MARK: - Reconnecting

private struct ReconnectingScreen: View {
    let onTrouble: () -> Void
    let onPickAnother: () -> Void
    @EnvironmentObject private var client: NimletClient

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                Spacer()
                ProgressView().controlSize(.large)
                Text(client.isPairing ? "Pairing with \(client.currentHostName ?? "your Mac")…" : "Reconnecting…")
                    .font(.title3.weight(.semibold))
                Text(subtitle(at: context.date))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                if let since = client.retryingSince, context.date.timeIntervalSince(since) > 20 {
                    // Long enough that waiting is no longer the plan. The
                    // commonest reasons, in the order they are usually true.
                    Text("Is the Mac awake, with Nimlet running in its menu bar, on the same Wi-Fi as this phone?")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                Spacer()
                Button("Reach the Mac another way…", action: onTrouble)
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 44)
                // This screen used to have no way off it except the gear.
                Button("Choose a different Mac", action: onPickAnother)
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(client.isPairing ? "Pairing" : "Reconnecting"). \(subtitle(at: context.date))")
        }
    }

    private func subtitle(at now: Date) -> String {
        if client.isPairing { return "Keep the code on your Mac's screen until this finishes." }
        let nothingSent = "Nothing is sent while the link is down."
        guard let last = client.lastConnectedAt else { return nothingSent }
        let seconds = Int(now.timeIntervalSince(last))
        let ago: String
        if seconds < 60 {
            ago = seconds == 1 ? "1 second" : "\(seconds) seconds"
        } else {
            let minutes = seconds / 60
            ago = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "Last seen \(ago) ago. " + nothingSent
    }
}

// MARK: - Why it can't connect

private struct TroubleScreen: View {
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Can't reach \(client.currentHostName ?? "your Mac")")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if let since = client.retryingSince {
                        Text("Retried for \(Int(Date().timeIntervalSince(since))) seconds.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    // Ordered by how often each one is actually the answer,
                    // not by how bad it would be.
                    cause("The Mac is asleep", "Wake it — Nimlet reconnects itself")
                    if let why = client.rememberedHosts.first.flatMap({ PhoneTrust.unavailable(forHost: $0.id) }) {
                        cause("Remote connection setup", why)
                    }
                    cause("No route to the Mac", "For another Wi-Fi or cellular, connect Tailscale on both devices or check the Mac's direct internet access setting")
                    cause("Nimlet isn't running on the Mac", "Its menu bar item is the pointer icon. Get it at nimlet.app/download if it was never installed.")
                    cause("Nimlet on the Mac is out of date", "Update it from nimlet.app/download")

                    Button {
                        client.retry()
                        dismiss()
                    } label: {
                        Text("Try again").frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .font(.body.weight(.semibold))

                    Text("Keep Nimlet open and in front. iOS suspends the socket when the app "
                         + "leaves the screen.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func cause(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
