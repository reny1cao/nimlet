import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var server: HostServer
    @EnvironmentObject private var store: TargetStore
    @EnvironmentObject private var state: HostState
    @ObservedObject private var registry = DeviceRegistry.shared
    @ObservedObject private var approvals = ApprovalBroker.shared
    @ObservedObject private var reach = RemoteReach.shared
    @ObservedObject private var relay = RelayService.shared
    @ObservedObject private var updates = UpdateCheck.shared
    @Environment(\.openSettings) private var openSettings
    /// What `PushSender` says about reaching phones that are asleep. Read
    /// across that object's own queue, so it arrives a moment after the menu
    /// opens rather than being available to read synchronously.
    @State private var push = ""
    @State private var copiedDiagnostics = false
    @State private var choosingTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let release = updates.available {
                updateBanner(release)
            } else if let newer = server.newerPhone {
                newerPhoneBanner(newer)
            }

            // Above everything else: it is the one thing in this menu with a
            // clock running on it.
            ForEach(approvals.pending) { request in
                approvalCard(request)
            }

            if !state.accessibilityGranted {
                accessibilityBanner
            }

            if !state.screenRecordingGranted {
                screenRecordingBanner
            }

            if registry.approved.isEmpty {
                pairingCard
            }

            targetCard
            tiles
            devicesCard
            awayCard
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { state.refreshPermissions(); updates.checkIfStale() }
        .task { PushSender.shared.summary { push = $0 } }
    }

    // MARK: Header

    /// Everything the menu is asking of you, counted, so a glance at the top
    /// says whether reading the rest is necessary.
    private var attentionCount: Int {
        approvals.pending.count
            + server.awaitingApproval.count
            + (state.accessibilityGranted ? 0 : 1)
            + (state.screenRecordingGranted ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.background)
                .frame(width: 32, height: 32)
                .background(.primary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Nimlet").font(.headline)
                    // The first thing anybody reporting a problem is asked.
                    Text(UpdateCheck.currentVersion)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(server.isListening ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(server.isListening ? "Listening as \(server.hostDisplayName)" : "Not listening")
                        .lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
                    .accessibilityLabel("\(attentionCount) waiting on you")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Things that need you

    /// A newer companion exists. Said here because this app has no other way
    /// of being updated, and nowhere else to say so.
    private func updateBanner(_ release: UpdateCheck.Release) -> some View {
        MenuNotice(symbol: "arrow.down.circle.fill", tint: .blue,
                   title: "Nimlet \(release.version) (\(release.build)) is available") {
            if let notes = release.notes, !notes.isEmpty {
                Text(notes).lineLimit(3)
            }
            Text("Download it, quit Nimlet, replace the copy in Applications, and open it again. Your pairing and approved phones are kept.")
        } actions: {
            Button("Download…") { updates.openDownload() }
        }
    }

    /// A phone running a newer Nimlet was turned away: the two ends must speak
    /// the same protocol, and the Mac is the end that is behind.
    private func newerPhoneBanner(_ phone: HostServer.NewerPhone) -> some View {
        MenuNotice(symbol: "arrow.down.circle", tint: .blue,
                   title: "\(phone.name) has a newer Nimlet than this Mac") {
            Text("It can't connect until the Mac companion is updated too.")
        } actions: {
            Button("Get the update…") { updates.openDownload() }
        }
    }

    /// The same decision the phone is being asked for, answerable here.
    ///
    /// Not a fallback: the Mac is where you are when the phone is in another
    /// room, and a blocked agent must never depend on one device being within
    /// reach. Denying is the outcome of doing nothing, so it is the plain
    /// button and approving is the deliberate one. A question shows its
    /// choices; one with several parts is left to the phone or the agent.
    private func approvalCard(_ request: ApprovalRequest) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = ApprovalClock.millis(at: context.date)
            let total = max(1, request.expiresAtEpochMillis - request.createdAtEpochMillis)
            let left = Double(max(0, request.expiresAtEpochMillis - now)) / Double(total)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    MenuSectionLabel("WAITING ON YOU")
                    Spacer()
                    // What happens if this window is never opened again.
                    Text("\(expiryWords(request)) \(ApprovalWait.clock(request.secondsRemaining(at: now)))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    SymbolTile(symbol: approvalSymbol(request.kind), tint: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                        Text(request.targetName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(request.detail)
                    .font(.system(size: 11, design: request.isQuestion ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Capsule()
                    .fill(Color.orange.opacity(0.2))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(Color.orange).frame(width: geometry.size.width * left)
                        }
                    }
                if request.isQuestion {
                    questionChoices(request)
                } else {
                    permissionChoices(request)
                }
                if request.returnsToMac {
                    Button("Answer in the agent instead") {
                        ApprovalBroker.shared.decide(id: request.id, with: ApprovalAnswer(decision: .deny, handBack: true), by: nil)
                    }
                    .buttonStyle(.link)
                    .font(.subheadline)
                }
            }
            .menuCard(tint: .yellow)
        }
    }

    private func expiryWords(_ request: ApprovalRequest) -> String {
        if request.returnsToMac { return "Back to the agent in" }
        return request.onExpiry == .approve ? "Approves in" : "Denies in"
    }

    @ViewBuilder private func permissionChoices(_ request: ApprovalRequest) -> some View {
        HStack(spacing: 8) {
            Button {
                ApprovalBroker.shared.decide(id: request.id, decision: .deny, by: nil)
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            Button {
                ApprovalBroker.shared.decide(id: request.id, decision: .approve, by: nil)
            } label: {
                Text("Approve").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        if let rule = request.alwaysAllowRule {
            Button {
                ApprovalBroker.shared.decide(id: request.id, with: ApprovalAnswer(decision: .approve, alwaysAllow: true), by: nil)
            } label: {
                Text("Approve, and don\u{2019}t ask again for \(rule)")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder private func questionChoices(_ request: ApprovalRequest) -> some View {
        if request.questions.count == 1, let question = request.questions.first,
           !question.allowsMultiple, !question.options.isEmpty {
            VStack(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    Button {
                        ApprovalBroker.shared.decide(id: request.id,
                                                     with: ApprovalAnswer(decision: .approve, answers: [option.label]),
                                                     by: nil)
                    } label: {
                        Text(option.label).frame(maxWidth: .infinity)
                    }
                    .help(option.detail ?? option.label)
                }
            }
            .controlSize(.regular)
        } else {
            Text("Answer it on your phone, or in the agent on this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        Button {
            ApprovalBroker.shared.decide(id: request.id, decision: .deny, reason: nil, by: nil)
        } label: {
            Text("Decline to answer").frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
    }

    private func approvalSymbol(_ kind: ApprovalRequest.Kind) -> String {
        switch kind {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .network: return "network"
        case .other: return "questionmark.circle"
        }
    }

    private var accessibilityBanner: some View {
        MenuNotice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   title: "Accessibility permission needed") {
            Text("Without it, clicks and typing are silently ignored.")
        } actions: {
            Button("Open Privacy & Security…") { state.openAccessibilitySettings() }
        }
    }

    /// Only in the way of the panel mirror, so it says so rather than implying
    /// the whole app is broken.
    private var screenRecordingBanner: some View {
        MenuNotice(symbol: "rectangle.on.rectangle", tint: .orange,
                   title: "Screen Recording is off") {
            Text("Window previews, screenshots and Mac audio need it. Typing and the pointer work without it. macOS applies the grant only to a fresh launch, so relaunch Nimlet after allowing it.")
        } actions: {
            Button("Open Privacy & Security…") { state.openScreenRecordingSettings() }
            Button("Relaunch") { Relaunch.now() }
        }
    }

    private var pairingCard: some View {
        MenuNotice(symbol: "qrcode", tint: .accentColor, title: "Pair your iPhone") {
            Text("Choose Pair a Phone and point your iPhone's Camera at the code. Nimlet opens by itself.")
        } actions: {
            Button("Pair a Phone…") { PairWindow.show() }
                .buttonStyle(.borderedProminent)
                .help("Show a QR code to scan with the iPhone's Camera")
        }
    }

    // MARK: Sending to

    /// Where the phone's words go, first among the settled parts of the menu
    /// because it is the one most often wrong: a pane that closed under a
    /// target swallows everything sent to it, and used to say so only as a
    /// suffix on a picker's title.
    private var targetCard: some View {
        let active = store.activeTarget
        return VStack(alignment: .leading, spacing: 8) {
            MenuSectionLabel("SENDING TO")
            Button {
                withAnimation(.snappy(duration: 0.2)) { choosingTarget.toggle() }
            } label: {
                HStack(spacing: 10) {
                    SymbolTile(symbol: active?.symbol ?? "questionmark", tint: nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(active?.name ?? "No target chosen")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(active.map(Self.deliveryDescription) ?? "Pick where the phone types")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: choosingTarget ? "chevron.up" : "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sending to \(active?.name ?? "nothing"). Change target")

            if choosingTarget {
                VStack(spacing: 0) {
                    ForEach(store.targets) { target in
                        Button {
                            store.setActive(target.id)
                            withAnimation(.snappy(duration: 0.2)) { choosingTarget = false }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: target.symbol)
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                Text(target.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if store.isUnresolved(target.id) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help("This pane is no longer running. Pick another one.")
                                }
                                if target.id == store.activeTargetID {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(MenuRowButtonStyle())
                    }
                }
                .transition(.opacity)
            }

            if let active, store.isUnresolved(active.id) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("That pane isn't running anymore, so nothing you send will arrive.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Pick Another Pane…") { openSettings(selecting: active.id) }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if let activity = server.lastActivity {
                Text(activity)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 2)
            }
        }
        .menuCard()
    }

    static func deliveryDescription(_ target: NimletTarget) -> String {
        switch target.kind {
        case .app: return "App · raise, then paste"
        case .tmux: return "tmux pane · send-keys"
        case .frontmost: return "Whatever has focus"
        }
    }

    private func openSettings(selecting targetID: String) {
        SettingsRoute.shared.targetID = targetID
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: Quick switches

    private var tiles: some View {
        HStack(spacing: 8) {
            ToggleTile(title: "Control", symbol: "keyboard",
                       onText: "Typing on", offText: "Paused",
                       isOn: Binding(get: { !state.injectionPaused },
                                     set: { state.injectionPaused = !$0 }))
                .help("Turn off to stay connected but stop moving the cursor and typing")

            ToggleTile(title: "Mac audio", symbol: "headphones",
                       onText: "Phones listen", offText: "Off",
                       isOn: $state.audioAllowed)
                .help("Send this Mac's audio to an approved phone when it asks for it")

            if LaunchNetworkPolicy.allowsAwayAccess {
                ToggleTile(title: "Away", symbol: "globe",
                           onText: "On cellular", offText: "Home only",
                           isOn: awayBinding)
                    .help("Let paired phones reach this Mac from outside this network")
            } else {
                ToggleTile(title: "Away", symbol: "globe",
                           onText: "", offText: "Local only",
                           isOn: .constant(false))
                    .disabled(true)
            }
        }
    }

    /// Reaching this Mac from away.
    ///
    /// Off by default, with the consequence written underneath rather than in
    /// a help tag: this opens a port on the internet to a program whose whole
    /// purpose is typing into this Mac. What the away card says afterwards is
    /// the truth about whether it worked, including the case where it cannot
    /// — a carrier-grade NAT at this end is a dead end, and a switch that stays
    /// on while silently achieving nothing is worse than one that says so.
    private var awayBinding: Binding<Bool> {
        Binding(get: { reach.isEnabled },
                set: { wanted in
                    reach.isEnabled = wanted
                    if wanted { server.startAway() } else { server.stopAway() }
                    // The phones that are already connected, which are the ones
                    // this is for. Waiting for the address list to happen to
                    // change would leave a phone at the desk without the key it
                    // needs for when it leaves — and on a Mac with no IPv6 and
                    // no mapping, the list does not change at all.
                    server.broadcastRemoteAccess()
                })
    }

    // MARK: Devices

    /// Approved devices that aren't connected right now. A phone left at home
    /// is exactly the one you want to be able to revoke.
    private var offlineApproved: [DeviceRegistry.Device] {
        registry.approved.filter { device in
            !server.connectedDevices.contains { $0.id == device.id }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                MenuSectionLabel("DEVICES")
                Spacer()
                // With nothing paired, the card at the top already says this.
                if !registry.approved.isEmpty {
                    Button { PairWindow.show() } label: {
                        Label("Pair a Phone", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.medium))
                    .help("Show a QR code to scan with the iPhone's Camera")
                }
            }
            .padding(.bottom, 2)

            if server.connectedDevices.isEmpty && offlineApproved.isEmpty && server.awaitingApproval.isEmpty {
                Text("No phone connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            ForEach(server.awaitingApproval) { device in
                DeviceRow(symbol: icon(for: device.name), tint: .orange, name: device.name) {
                    Text("Wants to connect").foregroundStyle(.orange)
                } trailing: {
                    Button("Not Now") { server.dismissWaiting(deviceID: device.id) }
                        .buttonStyle(.borderless)
                    Button("Approve") { server.approve(device) }
                        .buttonStyle(.borderedProminent)
                }
            }

            ForEach(server.connectedDevices.filter(\.approved)) { device in
                DeviceRow(symbol: icon(for: device.name), tint: nil, name: device.name, online: true) {
                    if device.isHearing {
                        // Said plainly. The menu bar's recording indicator
                        // means something is capturing; only this says the
                        // sound in this room is leaving it, and for whom.
                        Label("Connected · hearing this Mac", systemImage: "headphones")
                    } else {
                        Text("Connected")
                    }
                } trailing: {
                    DeviceMenu(name: device.name) {
                        Button("Revoke", role: .destructive) { server.revoke(deviceID: device.id) }
                    }
                }
            }

            ForEach(offlineApproved) { device in
                DeviceRow(symbol: icon(for: device.name), tint: nil, name: device.name, dimmed: true) {
                    Text("Not connected")
                } trailing: {
                    DeviceMenu(name: device.name) {
                        Button("Revoke", role: .destructive) { server.revoke(deviceID: device.id) }
                    }
                }
            }

            if !registry.revoked.isEmpty {
                MenuSectionLabel("REVOKED")
                    .padding(.top, 6)
                ForEach(registry.revoked) { device in
                    DeviceRow(symbol: icon(for: device.name), tint: nil, name: device.name, dimmed: true) {
                        Text("Can't connect")
                    } trailing: {
                        DeviceMenu(name: device.name) {
                            Button("Approve Again") {
                                server.approve(.init(id: device.id, name: device.name, approved: false))
                            }
                            // Off the list, not back on it: a phone that was
                            // sold or wiped has no business being remembered
                            // forever.
                            Button("Forget") { registry.forget(deviceID: device.id) }
                                .help("Stop listing this phone. If it ever connects again it will ask for approval like a new one.")
                        }
                    }
                }
            }

            if let error = server.lastError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .menuCard()
    }

    private func icon(for name: String) -> String {
        name == DeviceRegistry.toolName ? "terminal" : "iphone"
    }

    // MARK: Away from home

    @ViewBuilder private var awayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MenuSectionLabel("AWAY FROM HOME")
                Spacer()
                awaySummary
            }
            .padding(.bottom, 2)

            if !LaunchNetworkPolicy.allowsAwayAccess {
                Text("Local network only")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                relayRow
                // With the relay up, the router is no longer the way in, and a
                // warning about it was the loudest line in the menu about
                // nothing.
                if case .blocked = reach.status, relayRegistered {
                    EmptyView()
                } else {
                    directStatus
                }
                vpnRow
                pushRow
            }
        }
        .menuCard()
    }

    private var relayRegistered: Bool {
        RelayService.configured != nil && reach.isEnabled && relay.status == .registered
    }

    /// The one line that answers "can my phone get here from outside?", so
    /// the rows underneath are detail rather than the answer.
    @ViewBuilder private var awaySummary: some View {
        Group {
            if !reach.isEnabled {
                Text("Off").foregroundStyle(.secondary)
            } else if relayRegistered {
                Label("Reachable anywhere", systemImage: "checkmark")
                    .foregroundStyle(.green)
            } else {
                switch reach.status {
                case .reachable where reach.pairedPhoneCount > 0:
                    Label("Reachable", systemImage: "checkmark")
                        .foregroundStyle(.green)
                case .working:
                    Text("Checking…").foregroundStyle(.secondary)
                case .off:
                    Text("Off").foregroundStyle(.secondary)
                default:
                    Label("Not reachable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var directStatus: some View {
        switch reach.status {
        case .off:
            Text("Direct internet access is off. Local network and configured VPN routes remain available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .working:
            StatusRow(symbol: "network", title: "Router") {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Asking for a way in…")
                }
            }
        case .reachable:
            VStack(alignment: .leading, spacing: 3) {
                if reach.pairedPhoneCount == 0 {
                    // The port is open and the address found, and no phone
                    // can use either yet: the away port answers only to a
                    // phone paired by key. Green here used to say "done"
                    // about a path nothing could take.
                    Label("Address ready — pair a phone by QR code so it can use it",
                          systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    StatusRow(symbol: "network", title: "Router") {
                        Text(reach.pairedPhoneCount == 1
                             ? "Open for 1 phone"
                             : "Open for \(reach.pairedPhoneCount) phones")
                    }
                }
                if let detail = reach.detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                }
                Text("Only your paired phones can use it. Revoking one stops it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        case .blocked(let why):
            VStack(alignment: .leading, spacing: 4) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { reach.refresh() }
                    .controlSize(.small)
            }
        }
    }

    /// The connect relay, when one is configured: the way in that works behind
    /// a carrier's NAT, where everything above says there is none.
    @ViewBuilder private var relayRow: some View {
        if RelayService.configured != nil, reach.isEnabled {
            StatusRow(symbol: "point.3.connected.trianglepath.dotted", title: "Relay") {
                switch relay.status {
                case .registered:
                    Text("Connected")
                case .connecting:
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                    }
                case .failed(let why):
                    Text(why).foregroundStyle(.orange).lineLimit(2)
                case .off:
                    Text("Waiting for a paired phone")
                }
            }
        }
    }

    @ViewBuilder private var vpnRow: some View {
        let vpn = reach.candidates.filter { OverlayAddress.contains($0.host) }
        if !vpn.isEmpty {
            // One line however many addresses: the IPv6 twin of the Tailscale
            // address is the same route.
            StatusRow(symbol: "network.badge.shield.half.filled", title: "VPN") {
                Text(vpn[0].display)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help("With Tailscale on both devices, the phone reaches this Mac from any network.\n"
                  + vpn.map(\.display).joined(separator: "\n"))
        }
    }

    /// Whether a phone that is asleep can still be told.
    ///
    /// In the away card because it answers the same question that card does —
    /// can this Mac reach a phone that is not at the desk — asked about the
    /// case where the phone is not merely elsewhere but frozen.
    ///
    /// It is here at all because the failure is otherwise invisible: with no
    /// relay configured everything looks exactly as it does when it is working,
    /// right up until an agent blocks while the phone is in a pocket and
    /// nothing happens. A feature that silently does nothing is worse than one
    /// that says it is off.
    private var pushRow: some View {
        let notSetUp = push == "Not set up" || push.isEmpty
        return StatusRow(symbol: notSetUp ? "moon.zzz" : "bell.badge", title: "Sleeping phones") {
            Text(push.isEmpty ? "…" : push)
                .foregroundStyle(push == "Not set up" ? Color.orange : Color.secondary)
        }
        .help(push == "Not set up" ? "See Settings → Notifications" : "")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.borderless)
            // Used when something is wrong, not every time the menu opens.
            Menu("Help") {
                Button("Setup Guide…") { SetupWindow.show() }
                Button(copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics") {
                    Diagnostics.copyToPasteboard { copiedDiagnostics = true }
                }
                .help("Versions, permissions, connection state and the last few minutes of Nimlet's own log — nothing you typed or dictated")
                Divider()
                Button("Reveal Delivery Log…") { DeliveryLog.reveal() }
                Button("Reveal Image Inbox…") { AttachmentInbox.reveal() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Quit Nimlet") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

// MARK: - Pieces

/// The inset, rounded group every part of the menu sits in, after Control
/// Center: separate cards read as separate things at a glance, where a column
/// of dividers made every section look equally important.
private struct MenuCard: ViewModifier {
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
            )
    }

    private var fill: Color {
        if let tint { return tint.opacity(scheme == .dark ? 0.18 : 0.14) }
        return scheme == .dark ? .white.opacity(0.07) : .white.opacity(0.75)
    }
}

private extension View {
    func menuCard(tint: Color? = nil) -> some View {
        modifier(MenuCard(tint: tint))
    }
}

private struct MenuSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SymbolTile: View {
    let symbol: String
    let tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint ?? .primary)
            .frame(width: 30, height: 30)
            .background(
                (tint?.opacity(0.15) ?? Color.primary.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// A card that asks for something: an update, a permission, a first pairing.
private struct MenuNotice<Message: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder var message: Message
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) { message }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { actions }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .menuCard()
    }
}

/// One of the three switches under the target, after Control Center's
/// tiles: the state is the filled circle, readable without reading.
private struct ToggleTile: View {
    let title: String
    let symbol: String
    let onText: String
    let offText: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.1)),
                                in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(isOn ? onText : offText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .menuCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct DeviceRow<Status: View, Trailing: View>: View {
    let symbol: String
    let tint: Color?
    let name: String
    var online = false
    var dimmed = false
    @ViewBuilder var status: Status
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: symbol, tint: tint)
                .opacity(dimmed ? 0.6 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if online {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                status
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) { trailing }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

/// The rare, destructive actions on a device, a click further away than they
/// were: Revoke sat where a stray click in a narrow menu would land on it.
private struct DeviceMenu<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Options for \(name)")
    }
}

private struct StatusRow<Value: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .fixedSize()
            Spacer(minLength: 8)
            value
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// A row in the inline target list: highlighted under the pointer, the way a
/// menu item is, since that is what it stands in for.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
