import SwiftUI

/// The screen, in three bands.
///
/// It used to be four things in two layers: a status row, a trackpad, a send
/// band and a dock, with the panel floating over all of them and the keyboard
/// arriving in a sheet that covered the lot. Every one of those was a separate
/// visual language, and the two that mattered most — the pane you are driving
/// and the words you are about to send it — could not be on screen together.
///
/// Now there are three bands and nothing on top of them:
///
/// - the **stage**, which is a line of status and, under it, the picture of the
///   focused pane at exactly that window's proportions — tap it and it opens
///   full screen, which is where the Mac is driven from;
/// - the **pad**, which is the pointer surface and takes whatever height the
///   other two are not using;
/// - the **console** and the **dock**, which are where sending lives.
///
/// The keyboard no longer displaces any of it. Tapping the composer grows it in
/// place: the pad and the dock stand down, the stage shrinks a little, and the
/// pane you are typing at stays on screen — which is the whole reason the sheet
/// had to go.
struct ContentView: View {
    @ObservedObject private var pro = ProStore.shared
    @EnvironmentObject private var client: NimletClient
    @EnvironmentObject private var voice: VoiceCapture
    @EnvironmentObject private var panel: PanelClient
    @StateObject private var motion = MotionSteering()
    @StateObject private var replies = QuickReplyStore()
    @State private var pillPosition: CGPoint?
    @State private var pillMoveMode = false
    @State private var fanOut = FanOut()
    @State private var draft: TranscriptDraft?
    @State private var showingApprovals = false
    @State private var showingSettings = false
    @State private var surfaceConnection = SurfaceConnection()

    private struct SurfaceConnection: Equatable {
        var connected = false
        var approved = false
        var resuming = false
        var operable: Bool { connected && approved }
    }
    /// Who the recording is for, from the tap on the microphone until it is
    /// sent or discarded — including while the recognizer is still getting
    /// ready, and while it restarts in another language, so the console stays
    /// up and keeps its buttons through both.
    @State private var micTarget: NimletTarget?
    @AppStorage(DictationLanguage.key) private var dictationLanguage = ""
    @State private var showingTargets = false
    /// The dock's `+`: the picker, not the settings list. Adding something is
    /// what that button is for, and it used to open the screen you go to when
    /// you want to change something you already added.
    @State private var showingAdd = false
    /// Which target's windows are on the shelf. One at a time: it is a question
    /// about one app.
    @State private var shelfTargetID: String?
    /// Stored rather than held, so the switch for it can live in Settings —
    /// where hiding the mirror went when the stage lost its title bar.
    @AppStorage("mice.panel.shown") private var showPanel = true
    /// Off until it is asked for. Steering the pointer by tilting the phone is
    /// a real feature and a minority one, and it was a 62pt circle parked on
    /// the pad — the one surface on the screen you actually touch — for
    /// everybody, including everybody who has never pressed it.
    @AppStorage("mice.air.shown") private var showsAirPill = false
    @State private var isExpanded = false
    /// The composer has the keyboard. Reported up here rather than kept inside
    /// the console, because what it changes is the two bands above and below it.
    @State private var isComposing = false
    @State private var keyboardShown = false
    @State private var consoleHeight: CGFloat = 96
    @State private var noticeHeight: CGFloat = 0
    @State private var approvalHeight: CGFloat = 0
    private var isInputLayout: Bool { isComposing || keyboardShown }
    /// The safe area offered by the screen, excluding the keyboard. Reading
    /// the content stack here creates a loop: a tall mirror can grow the stack
    /// beyond that offer, and its measured height then keeps the mirror tall.
    @State private var bandHeight: CGFloat = 0
    /// How far the stage is zoomed in and what part of the window it is
    /// showing. Held here rather than by the band that draws it, because the
    /// gesture that moves it is on the pad — several hundred points below — and
    /// the two have to be looking at the same numbers.
    @State private var mirror = MirrorState()
    /// What the scroll strip is doing — a thumb on it, and how much of a flick
    /// is left after the thumb has gone. Only the strip's own ink cares.
    @State private var scrolling = ScrollStripState.idle
    /// The share of `bandHeight` the stage stands to, as the handle between it
    /// and the pad last left it. Stored, so the split someone chose is the
    /// split they come back to.
    ///
    /// Nil uses the default share. Both the default and a chosen share give the
    /// Mac the available area's shape when connecting or switching windows.
    @AppStorage("mice.stage.share") private var stageShare: Double?
    /// The share while the handle is held — written every frame of the drag,
    /// and only committed to `stageShare` when the finger lifts.
    @State private var draggingShare: CGFloat?
    /// Where the drag started from: the stage's height as it was actually
    /// drawn, which for a wide window is less than its ceiling — so the first
    /// point of an upward drag moves it, rather than first eating the slack.
    @State private var dragOrigin: CGFloat?
    /// The handle has just been let go, and the Mac's window has not caught
    /// up with the band's new shape yet. The picture keeps filling the band
    /// until it has, rather than showing bars for the fraction of a second the
    /// resize takes to come back.
    @State private var awaitingReshape = false
    /// The stack's width, which is the band's: the band takes all of it.
    @State private var bandWidth: CGFloat = 0

    /// The target whose windows are on the shelf, as the Mac currently
    /// describes it — not a copy taken when the shelf opened, so the pin drawn
    /// on the cards is the pin the Mac is actually holding.
    private var shelfTarget: NimletTarget? {
        guard let shelfTargetID else { return nil }
        return client.targets.first { $0.id == shelfTargetID }
    }

    /// Connected is not the same as usable: a phone the Mac has not approved
    /// yet can hold a socket open and do nothing with it, and drawing the
    /// trackpad over that is a lie about what a drag will do.
    private var isOperable: Bool {
        surfaceConnection.operable
    }

    /// The surface stays on screen through a link that is coming back.
    ///
    /// Not the same question as `isOperable`, and the difference is the whole
    /// point: a blip — leaving the app for a minute, Wi-Fi hesitating, the Mac
    /// changing address — used to replace the dock, the pad and the mirror with
    /// the "choose your Mac" screen and then build them again, so a two-second
    /// glance at another app read as the app having started from nothing. The
    /// bands stay where they are, dimmed and untouchable, and the status line
    /// above them says what is happening; the recovery screen is for a link that
    /// is a problem rather than a pause, which is what `isResuming` going false
    /// means.
    private var isHoldingSurface: Bool { isOperable || surfaceConnection.resuming }

    /// The window's bottom inset: the home indicator's band, or nothing on a
    /// phone with a Home button. Read from the window rather than a geometry
    /// reader, whose inset counts the keyboard too. The app is portrait only,
    /// so it does not change under a running screen.
    private var homeIndicatorInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        return scene?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// Above this, release stops meaning "paste and press Return". Below it the
    /// pause costs more than the mistake it would catch. Adjustable, because
    /// where it belongs depends entirely on what you dictate.
    @AppStorage("mice.reviewThreshold") private var reviewThreshold = 160

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let availableHeight = max(geometry.size.height - Metric.stackBottom, 0)
                VStack(spacing: 12) {
                    stage(in: availableHeight)
                    if client.appOperationNotice != nil {
                        AppOperationNotice()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
                    }

                    if isHoldingSurface {
                        Group {
                            if !client.approvals.isEmpty {
                                ApprovalBanner(requests: client.approvals) { showingApprovals = true }
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { approvalHeight = $0 }
                            }
                            // Both stand down for the keyboard. Neither can be used
                            // while it is up, and leaving them in place only means the
                            // composer is squeezed into whatever is left.
                            //
                            // The pad's slot stays flexible when the pad is gone. Without
                            // that this stack has nothing that stretches, so it centres
                            // itself in the space above the keyboard — the stage drifts
                            // down off the top of the screen and the composer floats
                            // clear of the keys it belongs against.
                            if !isInputLayout {
                                trackpad
                                    .overlay(alignment: .top) {
                                        if isStageShown && !client.hasProAccess {
                proPrompt("Live windows require Pro", detail: "Free controls work on the same local network. Look at your Mac's screen while using the trackpad.")
            } else if isStageShown { splitHandle }
                                    }
                            } else {
                                Spacer(minLength: 0)
                            }
                            console
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.onAppear { consoleHeight = geometry.size.height }
                                            .onChange(of: geometry.size.height) { _, height in consoleHeight = height }
                                    }
                                }
                            if !isInputLayout {
                                TargetDock(fanOut: $fanOut,
                                           shelfTargetID: $shelfTargetID,
                                           onManage: { showingAdd = true })
                                    // Down into the home indicator's band, to the
                                    // same distance from the bottom edge as from
                                    // the sides. Negative padding, so the bands
                                    // above keep the room it gives back.
                                    .padding(.bottom, Metric.dockInset - Metric.stackBottom - homeIndicatorInset)
                                    .overlay(alignment: .top) {
                                        if let target = shelfTarget {
                                            WindowShelf(target: target) {
                                                withAnimation(.spring(duration: 0.24)) { shelfTargetID = nil }
                                            }
                                            .id(target.id)
                                            // The picker floats above the Dock; it consumes no stack height.
                                            .offset(y: -WindowShelf.height(hasWindows:
                                                !(client.windowRoster(for: target.id)?.windows.isEmpty ?? true)) - 12)
                                            .transition(.opacity)
                                        }
                                    }
                                    .accessibilityIdentifier("target-dock")
                                    .task {
                                        // Ask for the mic here, not on the first hold, so
                                        // the first thing you try to dictate isn't lost to
                                        // a permission alert.
                                        await voice.primePermissions()
                                    }
                            }
                        }
                        // Held up but not live. `allowsHitTesting` as well as
                        // `disabled`, because the pad is a UIKit view and takes
                        // touches whatever the SwiftUI environment says — a drag
                        // that goes nowhere is worse than one the screen has
                        // visibly stood down from.
                        .disabled(!isOperable)
                        .allowsHitTesting(isOperable)
                        .opacity(isOperable ? 1 : 0.45)
                        .animation(.easeInOut(duration: 0.2), value: isOperable)
                    } else {
                        ConnectFlow()
                        Spacer(minLength: 0)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, Metric.stackBottom)
                .animation(.spring(duration: 0.3), value: isInputLayout)
                .animation(.spring(duration: 0.26), value: voice.isRecording)
                .onAppear {
                    bandHeight = availableHeight
                    bandWidth = max(geometry.size.width - 2 * Metric.gutter, 0)
                }
                .onChange(of: geometry.size) { _, new in
                    bandHeight = max(new.height - Metric.stackBottom, 0)
                    bandWidth = max(new.width - 2 * Metric.gutter, 0)
                }
            }
        }
        // In this screen's own stack rather than a `fullScreenCover`: inside
        // that cover, SwiftUI's hit testing was dead — the viewer's buttons and
        // a bare `onTapGesture` both never fired, while the raw touch surface
        // over the picture kept working. Here they all work, and the mirror
        // keeps the one connection and the one decoder it already had.
        .overlay {
            if isExpanded {
                PanelViewer(onClose: { isExpanded = false },
                            onPickWindow: mirrorTargetID.map { id in { openShelf(for: id) } },
                            onOpenWindow: openWindowAction)
                    .environmentObject(panel)
                    .environmentObject(client)
                    .transition(.opacity)
            }
        }
        // A different window is a different thing to be zoomed into.
        .onChange(of: panel.title) { _, _ in
            mirror.focus.reset()
            mirror.anchor = mirror.focus.centre
        }
        .modifier(PanelLifecycle(shown: showPanel))
        .onReceive(client.$state.combineLatest(client.$status, client.$isResuming)) { state, status, resuming in
            // Published values arrive before the model stores them. Keep the
            // surface's input gate in view state so a successful welcome also
            // re-enables the controls that were held during reconnection.
            let next = SurfaceConnection(connected: state.isConnected,
                                         approved: status?.deviceApproved == true,
                                         resuming: resuming)
            if surfaceConnection != next { surfaceConnection = next }
        }
        .onChange(of: isOperable, initial: true) { _, operable in
            remoteLog.info("control surface: operable=\(operable, privacy: .public) connected=\(client.state.isConnected, privacy: .public) approved=\(client.status?.deviceApproved == true, privacy: .public) resuming=\(client.isResuming, privacy: .public)")
        }
        .onAppear {
            // The zoomed stage follows the Mac's pointer, because there is no
            // gesture spare to pan it with: one finger on the pad is the
            // pointer and two are the scroll. Following the cursor is better
            // than a gesture anyway — it is where the person is looking, and it
            // is already being driven by the thumb that is on the pad.
            panel.onPointerMoved = { [stage = $mirror, weak client] place in
                // Only while this phone is the one moving it. The Mac's own
                // user moving the mouse, or an application warping the cursor,
                // would otherwise drag the picture out from under somebody who
                // had deliberately panned it somewhere else.
                guard client?.isDrivingPointer == true else { return }
                Self.follow(place, in: stage)
            }
        }
        .overlay(alignment: .top) { ToastView() }
        .onChange(of: isComposing) { _, composing in
            panel.setWindowFitSuspended(composing || keyboardShown)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
            panel.setWindowFitSuspended(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardShown = false
            panel.setWindowFitSuspended(isComposing)
        }
        .sheet(item: $draft) { pending in
            TranscriptReview(draft: pending) { edited, submit in
                client.send(.text(TextPayload(text: edited,
                                              targetID: pending.targetID,
                                              submit: submit)))
            }
        }
        .sheet(isPresented: $client.showingPro) { ProSheet() }
        .sheet(isPresented: $showingApprovals) {
            ApprovalSheet(requests: client.approvals,
                          focusID: client.approvalRequestID,
                          isReaching: !client.state.isConnected) { request, answer in
                client.decide(request.id, answer)
                if client.approvals.isEmpty { showingApprovals = false }
            }
            .onDisappear { client.approvalRequestID = nil }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(reviewThreshold: $reviewThreshold,
                          onManageTargets: {
                              showingSettings = false
                              showingTargets = true
                          })
        }
        .sheet(isPresented: $showingTargets) {
            TargetsView(replies: replies)
        }
        // A notification was tapped, and the card it was about is on this
        // sheet. Presented even when the approval has since been answered
        // elsewhere: the sheet says so, and coming back to an app that ignored
        // the tap is worse than coming back to "somebody already dealt with
        // that".
        .onChange(of: client.wantsApprovals) { _, wanted in
            guard wanted else { return }
            client.wantsApprovals = false
            showingApprovals = true
        }
        .onChange(of: client.shelfRequestID) { _, requested in
            // The Mac could not put a target where it was pointed, and has sent
            // the windows that do exist. Put them in front of the user rather
            // than leaving a tile that quietly does nothing.
            guard let requested else { return }
            withAnimation(.spring(duration: 0.28)) { shelfTargetID = requested }
            client.shelfRequestID = nil
        }
        .sheet(isPresented: $showingAdd) {
            // Handing one sheet to the next in the same frame leaves SwiftUI
            // presenting onto a view that is still going away, and the second
            // one silently never appears.
            AppBrowser {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    showingTargets = true
                }
            }
        }
    }

    // MARK: - Band one: the panel

    /// One line of status, and under it the picture of the Mac.
    ///
    /// The line is outside the picture on purpose, and it is the second attempt
    /// at that. The first put the status on the picture's top edge as a
    /// floating capsule — which cost no layout height and covered the corner of
    /// a window you were trying to read, and then, once the mirror became
    /// something you touch, covered a part of it you could no longer reach.
    /// Chrome over a live picture is chrome in the way. It is a short line
    /// just above the panel now — a dot, a number, and the way into Settings —
    /// close enough to it to read as the picture's own caption rather than as
    /// a second thing on the screen.
    @ViewBuilder private func stage(in height: CGFloat) -> some View {
        // Reserve the status line (26 + 2), both stack gaps, and all controls.
        // The preview gives up room first; no minimum can push Send under the keys.
        let notices = client.appOperationNotice == nil ? 0 : noticeHeight + 12
        let approvals = client.approvals.isEmpty ? 0 : approvalHeight + 12
        let inputHeight = max(height - consoleHeight - 52 - notices - approvals, 0)
        VStack(spacing: 2) {
            StatusLine(onSettings: { showingSettings = true },
                       onShowPanel: showsPanelToggle ? showPanelBand : nil)
            if isStageShown {
                PanelBand(maxHeight: isInputLayout ? inputHeight
                              : Metric.stage(in: height, composing: false, share: currentShare),
                          fillsHeight: !isInputLayout,
                          fillsPicture: !isInputLayout && (draggingShare != nil || awaitingReshape),
                          fitsWindow: !isInputLayout && !isExpanded,
                          mirror: $mirror,
                          onOpen: { isExpanded = true },
                          onPickWindow: mirrorTargetID.map { id in { openShelf(for: id) } },
                          onOpenWindow: openWindowAction)
                    .environmentObject(panel)
            }
        }
        .overlay(alignment: .bottom) {
            if let status = client.status, !status.accessibilityGranted {
                Text("Grant Accessibility to Nimlet on your Mac — clicks and typing are being ignored")
                    .font(.caption2)
                    .foregroundStyle(Palette.attention)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 20)
            }
        }
    }

    /// Keep the cursor in view, and write nothing when it is already in view.
    ///
    /// The guard is the point of this method. The pointer reports as often as
    /// the mirror has frames, the follow moves the view only when the cursor
    /// nears an edge — which is rarely — and assigning an unchanged value to
    /// `@State` re-renders the screen just as thoroughly as assigning a changed
    /// one. Without the comparison, driving the pointer would re-lay out the
    /// whole app at the frame rate of the mirror.
    /// Static, and through a `Binding` rather than through `self`.
    ///
    /// This closure outlives the view value that installs it — it is held by the
    /// panel client for the life of the connection — so capturing `self` would
    /// be writing state through a snapshot of a struct taken at `onAppear`. A
    /// binding is the handle to the live storage, and is the supported way to
    /// mutate state from an escaping closure.
    private static func follow(_ place: CGPoint, in stage: Binding<MirrorState>) {
        var state = stage.wrappedValue
        guard state.canZoom, state.focus.isZoomed else { return }
        var moved = state.focus
        moved.keep(place, inViewWithin: 0.22, card: state.card, picture: state.picture)
        guard moved != state.focus else { return }
        state.focus = moved
        stage.wrappedValue = state
    }

    /// Pinching the pad, applied to the picture above it.
    ///
    /// Anchored on the Mac's pointer when it is in the window, so pinching zooms
    /// in on whatever you were just doing rather than on the middle of a window
    /// you may not be looking at.
    private func zoomStage(by factor: CGFloat) {
        guard mirror.canZoom else { return }
        mirror.anchor = panel.pointerInWindow ?? mirror.focus.centre
        mirror.magnify(by: factor)
    }

    /// Only when there is a mirror to bring back and no mirror on screen.
    private var isStageShown: Bool { isHoldingSurface && showPanel && !isExpanded }

    private var currentShare: CGFloat {
        draggingShare ?? stageShare.map { CGFloat($0) } ?? Metric.stageShare
    }

    /// The seam between the stage and the pad, and the handle that moves it.
    ///
    /// Sits in the gap between the two bands and reaches a few points into
    /// each, so a thumb aimed at the seam finds it. Laid over the pad rather
    /// than placed in the stack, so it costs no height of its own — and the
    /// pad is drawn after the stage, so this is on top of both.
    ///
    /// The picture follows the finger every frame: the band is a box around a
    /// layer drawn with `resizeAspect`, so resizing it is a layout pass and
    /// nothing more. What the Mac encodes at is only re-asked for once the
    /// finger lifts (see `PanelBand`), because each ask rebuilds the capture.
    private var splitHandle: some View {
        Capsule()
            .fill(Color.white.opacity(draggingShare == nil ? 0.22 : 0.5))
            .frame(width: draggingShare == nil ? 36 : 48, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            // Centred on the 12-point gap above the pad.
            .offset(y: -20)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        guard bandHeight > 0 else { return }
                        if dragOrigin == nil {
                            dragOrigin = mirror.card.height > 0
                                ? mirror.card.height
                                : Metric.stage(in: bandHeight, composing: false, share: currentShare)
                            Haptics.dragStart()
                        }
                        let wanted = ((dragOrigin ?? 0) + value.translation.height) / bandHeight
                        let range = Metric.stageShareRange
                        let clamped = min(max(wanted, range.lowerBound), range.upperBound)
                        var plain = Transaction()
                        plain.disablesAnimations = true
                        withTransaction(plain) { draggingShare = clamped }
                    }
                    .onEnded { _ in
                        if let draggingShare {
                            stageShare = Double(draggingShare)
                            reshapeMac(to: draggingShare)
                        }
                        draggingShare = nil
                        Haptics.dragEnd()
                        dragOrigin = nil
                    }
            )
            // Back to the default split.
            .onTapGesture(count: 2) {
                Haptics.click()
                withAnimation(.spring(duration: 0.3)) { stageShare = nil }
            }
            .animation(.easeOut(duration: 0.15), value: draggingShare == nil)
            .accessibilityElement()
            .accessibilityLabel("Resize mirror")
            .accessibilityValue("\(Int((currentShare * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 0.05 : -0.05
                let range = Metric.stageShareRange
                stageShare = Double(min(max(currentShare + step, range.lowerBound), range.upperBound))
            }
    }

    /// Ask the Mac to give the mirrored window the band's new shape, so a
    /// taller band is a taller window rather than the same one with black
    /// above and below it.
    ///
    /// Once, where the finger lifts — never during the drag. It was a few
    /// times a second, and every one of those resized a real window, re-fitted
    /// the capture, rebuilt the encoder at a new size and waited on a
    /// keyframe: the picture flickered for the whole drag and the Mac's window
    /// juddered behind it. During the drag the picture fills the band on its
    /// own (see `fillsPicture`), so there is nothing to wait for.
    private func reshapeMac(to share: CGFloat) {
        guard panel.isVideo, bandWidth > 0 else { return }
        let height = Metric.stage(in: bandHeight, composing: false, share: share)
        guard height > 0 else { return }
        client.send(.reshapePanel(aspect: Double(bandWidth / height)))
        awaitingReshape = true
        Task { @MainActor in
            // Long enough for the resize, the new capture size and a keyframe
            // to come back; harmless if they come sooner, because once the
            // window is the band's shape filling it and fitting it are the
            // same picture.
            try? await Task.sleep(for: .milliseconds(1500))
            awaitingReshape = false
        }
    }

    private var showsPanelToggle: Bool {
        client.state.isConnected && !showPanel
    }

    /// Whose windows the mirror is showing, as far as this screen can tell —
    /// which is the target the Mac says is focused, and only if it is an app.
    /// A tmux pane has no window shelf to offer.
    private var mirrorTargetID: String? {
        guard let id = client.activeTargetID,
              let target = client.targets.first(where: { $0.id == id }),
              target.kind == .app
        else { return nil }
        return id
    }

    /// The direct way out of a stopped mirror, where the Mac can do it.
    ///
    private var openWindowAction: (() -> Void)? {
        guard let id = mirrorTargetID else { return nil }
        return { openMirrorWindow(for: id) }
    }

    /// Asks for it.
    ///
    /// Nil window id, because the target is already pointed at the one that
    /// got minimised — there is nothing to choose between, and asking the
    /// phone to name it would mean holding a copy of what the Mac already
    /// knows.
    private func openMirrorWindow(for targetID: String) {
        Haptics.click()
        client.openWindow(nil, for: targetID)
    }

    /// The other way out: the shelf, for the target whose window stopped. Same
    /// band the dock raises, so there is one window picker in the app and not
    /// two.
    private func openShelf(for targetID: String) {
        guard client.requirePro() else { return }
        Haptics.click()
        withAnimation(.spring(duration: 0.28)) { shelfTargetID = targetID }
    }

    private func showPanelBand() {
        guard client.requirePro() else { return }
        Haptics.click()
        withAnimation(.spring(duration: 0.3)) { showPanel = true }
    }

    private func proPrompt(_ title: String, detail: String) -> some View {
        Button { client.showingPro = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "lock.fill").font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text("See Nimlet Pro").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Band three: the console

    /// One band, two states. Sending is a field and a row of keys; dictating
    /// replaces both with what the microphone is hearing — in the same place,
    /// at the same width, rather than in a card floating over the trackpad.
    @ViewBuilder private var console: some View {
        if !client.hasProAccess {
            proPrompt("Text and voice input require Pro", detail: "Keep working from your iPhone with live windows, input and remote access.")
        } else if micTarget != nil || voice.isRecording || voice.isPreparing || voice.hitDurationLimit {
            DictationConsole(canSend: micTarget != nil && (voice.isRecording || voice.hitDurationLimit),
                             onSend: finishTapDictation,
                             onDiscard: cancelTapDictation,
                             onLanguage: switchDictationLanguage)
        } else {
            SendBand(store: replies,
                     fanOut: $fanOut,
                     isComposing: $isComposing,
                     onDictate: toggleTapDictation)
        }
    }

    /// The visible, non-gesture way to dictate.
    ///
    /// Hold-to-talk on a tile is faster and is what you learn, but it is a
    /// custom gesture, and a custom gesture cannot be the only way to reach a
    /// feature: a switch-control or voice-control user never performs it, and
    /// neither does anyone whose other hand is holding a coffee. Tap to start,
    /// tap to send, and a discard beside it.
    ///
    /// Send is a button in the console. The console takes the composer's place
    /// while it records — microphone included — and it used to say "Tap the
    /// microphone to send" over a microphone that was no longer on the screen,
    /// so a tapped dictation could be discarded and never sent.
    private func toggleTapDictation(_ target: NimletTarget) {
        guard client.requirePro() else { return }
        if micTarget != nil { finishTapDictation(); return }
        guard !voice.isPreparing else { return }
        micTarget = target
        Haptics.recordStart()
        client.requestVocabularyIfNeeded(for: target.id)
        startRecording(for: target)
    }

    private func startRecording(for target: NimletTarget) {
        Task {
            await voice.start(vocabulary: client.vocabulary(for: target.id))
            // Discarded, or sent, while the recognizer was getting ready.
            guard micTarget?.id == target.id else { return }
            guard voice.isRecording else {
                micTarget = nil
                Haptics.failure()
                client.note(voice.errorMessage ?? "Couldn't start dictation")
                return
            }
        }
    }

    private func finishTapDictation() {
        guard let recording = micTarget else { return }
        micTarget = nil
        Haptics.recordEnd()
        Task {
            let text = await voice.stop()
            guard let text, !text.isEmpty else {
                Haptics.failure()
                client.note(voice.errorMessage ?? "Didn't catch that")
                return
            }
            deliver(transcript: text, from: recording)
        }
    }

    /// Choosing another language part-way through starts the recording again
    /// in it. What was heard so far was heard as the wrong language, which is
    /// the usual reason for switching, so it is not worth keeping.
    private func switchDictationLanguage(to id: String) {
        guard id != dictationLanguage else { return }
        dictationLanguage = id
        Haptics.secondaryClick()
        guard let target = micTarget else { return }
        Task {
            await voice.cancel()
            // A start still fetching the previous language's model backs out
            // only once that returns, and a new start refuses to begin before.
            while voice.isPreparing { try? await Task.sleep(for: .milliseconds(50)) }
            guard micTarget?.id == target.id else { return }
            startRecording(for: target)
        }
    }

    private func cancelTapDictation() {
        micTarget = nil
        Task {
            await voice.cancel()
            Haptics.failure()
            client.note("Discarded")
        }
    }

    /// Anything long enough to be worth checking gets checked first. Release
    /// used to mean paste-and-press-Return with no preview and no undo, and the
    /// dictation console cannot serve as the approval surface because most of
    /// the time it is not touchable.
    private func deliver(transcript: String, from target: NimletTarget) {
        if transcript.count > reviewThreshold {
            draft = TranscriptDraft(text: transcript,
                                    targetID: target.id,
                                    targetName: target.name,
                                    allowAutoSubmit: target.allowAutoSubmit)
        } else {
            client.send(.text(TextPayload(text: transcript, targetID: target.id)))
        }
    }

    // MARK: - Band two: the pad

    private var trackpad: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )

                // The two lines of instructions are gone. A blank rounded
                // rectangle sitting under your thumb is already the whole
                // affordance, and the sentence explaining it was read once and
                // then looked past for the life of the app — while occupying
                // the middle of the only surface on screen you actually touch.
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.10))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                TrackpadView(
                    client: client,
                    // Bled out into the screen's gutter, so the strip reaches
                    // the glass. The pad stops 14 points short of it, which
                    // meant the cheapest aim on the phone — a thumb resting on
                    // the edge — landed in the margin and moved the pointer.
                    scrollStripRect: ScrollStripGeometry.rect(in: geometry.size,
                                                             bleed: Metric.gutter),
                    // Two fingers move the picture above and never the Mac —
                    // the same thing they do on the mirror itself, which is why
                    // they can mean it here.
                    onPan: { translation in mirror.pan(by: translation) },
                    onScrollStripChanged: { scrolling = $0 },
                    // Pinching the pad enlarges the picture above it. Nothing
                    // is sent to the Mac: the stream already carries more
                    // detail than a tile can draw, so this is arithmetic at
                    // this end — and the alternative, injecting ⌘-scroll,
                    // changes the real application's zoom for whoever is
                    // sitting in front of it.
                    onZoom: { magnification in zoomStage(by: 1 + CGFloat(magnification)) },
                    pillRect: pillRect(in: geometry.size),
                    onPillSteerBegan: {
                        motion.start { dx, dy in client.sendMove(dx: dx, dy: dy) }
                    },
                    onPillSteerEnded: { motion.stop() },
                    onPillMoved: { centre in
                        let clamped = clampPill(centre, in: geometry.size)
                        pillPosition = clamped
                        savePillPosition(clamped, in: geometry.size)
                    },
                    onPillSlide: { delta in
                        // Second speed: deliberately geared up, so a short
                        // thumb slide covers ground the wrist would not.
                        let boost = UserDefaults.standard.object(forKey: "mice.air.slideGain") as? Double ?? 2.6
                        client.sendMove(dx: Double(delta.x) * boost, dy: Double(delta.y) * boost)
                    },
                    onPillMoveModeChanged: { pillMoveMode = $0 }
                )

                if isAirPillShown {
                    AirPill(position: pillCentre(in: geometry.size),
                            isSteering: motion.isSteering,
                            isMoveMode: pillMoveMode)
                }

                // Drawn over the pad, touched through it: the surface below
                // owns these touches, the same way it owns the pill's.
                ScrollStrip(state: scrolling)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            // A bright panel held lit beside the keyboard all afternoon is most
            // of what "the phone runs hot" means. Touching it brings it back.
            // It steps back again while the microphone is open, where the thing
            // worth reading is a band below it.
            .opacity(client.isIdle ? 0.4 : voice.isRecording ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.45), value: client.isIdle)
            .animation(.easeOut(duration: 0.2), value: voice.isRecording)
        }
        .frame(maxHeight: .infinity)
    }

    /// Switched on, and on a phone whose sensors can do it.
    private var isAirPillShown: Bool { showsAirPill && motion.isAvailable }

    /// The pill's circle, used so the trackpad can route those touches to it.
    /// Empty when there is no pill, or the pad would hand a corner of itself to
    /// something that is not on screen.
    private func pillRect(in size: CGSize) -> CGRect {
        guard isAirPillShown else { return .zero }
        let centre = pillCentre(in: size)
        let side: CGFloat = 70
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    /// Defaults to the lower-left of the pointer area; persisted per device.
    private func pillCentre(in size: CGSize) -> CGPoint {
        // Clamped on the way out: the pad shrinks when the stage is dragged
        // taller, and a pill placed near its bottom would fall off it.
        if let pillPosition { return clampPill(pillPosition, in: size) }
        if let stored = storedPillPosition {
            return CGPoint(x: stored.x * size.width, y: stored.y * size.height)
        }
        return CGPoint(x: 55, y: size.height - 55)
    }

    private func clampPill(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let half: CGFloat = 39
        return CGPoint(x: min(max(point.x, half), size.width - half),
                       y: min(max(point.y, half), size.height - half))
    }

    private var storedPillPosition: CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "mice.air.x") != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: "mice.air.x"),
                       y: defaults.double(forKey: "mice.air.y"))
    }

    /// Stored as a fraction of the pointer area so it survives rotation and
    /// different screen sizes.
    private func savePillPosition(_ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        UserDefaults.standard.set(point.x / size.width, forKey: "mice.air.x")
        UserDefaults.standard.set(point.y / size.height, forKey: "mice.air.y")
        // Written on every drag frame but coalesced by UserDefaults; flushing
        // here means the position survives a hard kill of the app.
        UserDefaults.standard.synchronize()
    }
}

struct TranscriptDraft: Identifiable {
    let id = UUID()
    var text: String
    let targetID: String
    let targetName: String
    /// False when the Mac's own policy forbids Return on this target. The
    /// switch in the sheet is then off and locked: this is policy, and a
    /// per-message override must not be able to beat it.
    let allowAutoSubmit: Bool
}

// MARK: - The panel

/// The picture of the Mac, at exactly the shape of the Mac.
///
/// It used to be a card: a black surface with a white hairline around it, a
/// 22pt corner of its own, and a height clamped into a range. Every one of
/// those fought the picture. The clamp meant a window whose proportions were
/// not the ones somebody guessed here arrived with the card claiming height it
/// then refused to draw in — and filling that space instead meant cutting a
/// column of the window away to do it. The corner and the hairline drew a
/// second rounded rectangle around artwork that already has one, because a Mac
/// window is captured opaque: its own rounded corner, and the black outside
/// it, arrive in the frames as pixels.
///
/// The Mac fits its window to this band's available area. Frames use
/// `resizeAspect`, so an app that enforces a minimum or fixed size still shows
/// its whole window. Its own captured corners scale with the picture.
///
/// Tapping it opens the detail view, which is where the Mac is driven from.
private struct PanelBand: View {
    @EnvironmentObject private var panel: PanelClient
    /// The tallest it may stand. Width it takes all of, when the shape allows.
    let maxHeight: CGFloat
    /// Reserve the available height while the Mac adopts this area's shape.
    /// A window constrained by its app stays centred in the available space.
    var fillsHeight = false
    /// Fill the band with the picture, trimming whatever overhangs, instead of
    /// fitting it. Only while the band is being resized: the Mac is about to
    /// make the window the band's shape, and until it has, bars that appear
    /// and disappear under the finger are the flicker this exists to remove.
    var fillsPicture = false
    /// The detail mirror owns fitting while open. Typing keeps the last shape
    /// so the keyboard does not resize the Mac window in the middle of input.
    var fitsWindow = true
    /// How far in the pad has pinched, and what part of the window that leaves
    /// on screen. Owned by the screen, because the gesture is not here.
    @Binding var mirror: MirrorState
    let onOpen: () -> Void
    /// Handed down to the placeholder, which is the only state that offers
    /// either of them.
    var onPickWindow: (() -> Void)?
    /// Brings back the window this target is pointed at.
    var onOpenWindow: (() -> Void)?

    /// No frames, and a reason instead of a picture.
    ///
    /// The band's whole design is that it *is* the picture — no card, no
    /// border, no corner of its own, because the window already has all
    /// three and they arrive in the frames. That is right whenever there are
    /// frames. When there are none it leaves a hole: full width, full height,
    /// no edges, sitting directly above a trackpad that is also a dark
    /// rectangle and is the one you are meant to put your thumb on.
    ///
    /// So the empty state is the one case that draws itself. A dashed edge,
    /// because that is what "nothing here yet" looks like everywhere else and
    /// because it cannot be mistaken for the solid surface below it.
    private var isPlaceholder: Bool {
        panel.message != nil || (!panel.isVideo && panel.screen == nil)
    }
    /// The width the band has to work with: what the parent *offers*, never
    /// what the picture ended up being.
    ///
    /// It used to be read by a zero-height probe sitting in the same stack as
    /// the picture. A stack is as wide as its widest child, so the moment one
    /// measurement came back too large — a sheet mid-transition, a return from
    /// the background — the picture was drawn that wide, the stack grew to fit
    /// it, the probe read the new width back, and the band was stuck wider
    /// than the phone with the status row and the dock clipped at both edges
    /// until a cold launch threw the number away.
    ///
    /// The probe is a frame that takes the proposal in full whatever is inside
    /// it, so what it reads is the offer. That needs `minWidth: 0`: with only
    /// `maxWidth` a frame is never narrower than its child, so the picture
    /// still fed its own width back and the latch survived (build 25, QA
    /// 2026-10-03: 722 points wide, an iPhone 13 Pro's landscape width).
    @State private var available: CGFloat = 0

    var body: some View {
        picture
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { available = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, new in available = new }
                }
            )
            .clipped()
    }

    private var picture: some View {
        let box = fitted
        return content(in: box)
            .frame(width: box?.width, height: box?.height)
            // Only a picture opens, and only a picture is pinched. A
            // placeholder's tap used to lead to the same sentence at three
            // times the size, and it would now be a tap wrapped around the one
            // button that is a way out of it — two things in the same place,
            // one of which does nothing.
            .contentShape(Rectangle())
            .onTapGesture { if !isPlaceholder { onOpen() } }
            // Pinching the tile means the same thing as tapping it — a closer
            // look — and it is the gesture the hand reaches for first. The pad
            // is where a pinch zooms this band in place; a pinch *on* it opens
            // the mirror, where the Mac can also be touched.
            .gesture(
                MagnifyGesture(minimumScaleDelta: 0.08)
                    .onEnded { value in
                        if !isPlaceholder, value.magnification > 1 { onOpen() }
                    }
            )
            .accessibilityElement(children: isPlaceholder ? .contain : .ignore)
            .accessibilityAddTraits(isPlaceholder ? [] : .isButton)
            .accessibilityLabel(isPlaceholder ? "" : "Mirror of your Mac")
            .accessibilityHint(isPlaceholder
                               ? ""
                               : "Pinch the trackpad below to enlarge it. Tap to open it full screen, where it can be touched")
            .onAppear { settle(box) }
            .onChange(of: available) { _, _ in settle(fitted) }
            .onChange(of: panel.videoSize) { _, _ in settle(fitted) }
            .onChange(of: panel.streamCrop) { _, _ in settle(fitted) }
            // The handle above the pad is being dragged. Follow it every frame,
            // but leave what the Mac encodes at to the settled task below —
            // asking per frame would rebuild the capture for every point moved.
            .onChange(of: maxHeight) { _, _ in measure(fitted) }
            .task(id: settled) {
                // Only what a pinch settles on is ever asked for: each of these
                // re-decides the encode on the Mac, and re-deciding it per frame
                // of a gesture spends the gesture tearing the capture down and
                // building it again.
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                if fitsWindow { panel.setWindowFit(points: fitBox) }
                publishCrop()
                publishViewport()
            }
    }

    /// The picture, drawn through whatever the pad has done to it.
    ///
    /// Two rectangles rather than one, for the reason the full-screen mirror
    /// gives: past about 3x the Mac sends the region being read rather than the
    /// whole window, and those frames are a rectangle *of* the window. The
    /// window is what is laid out; the crop is undone where the frames are
    /// placed inside it. At rest both are the same rectangle and this is exactly
    /// what it was before.
    @ViewBuilder private func content(in box: CGSize?) -> some View {
        if let box, panel.message == nil, panel.isVideo, mirror.picture != .zero {
            let drawn = mirror.focus.drawn(card: box, picture: mirror.picture)
            let origin = mirror.focus.origin(card: box, picture: mirror.picture)
            let stream = panel.streamCrop
            // Filling only at rest: zoomed in, the arithmetic below already
            // decides what is on screen, and a crop is a rectangle of the
            // window that only places correctly by that arithmetic.
            let fills = fillsPicture && !mirror.focus.isZoomed && stream == MirrorCrop.whole
            let arrived = fills ? box : CGSize(width: drawn.width * stream.width,
                                               height: drawn.height * stream.height)
            let arrivedOrigin = fills ? .zero : CGPoint(x: origin.x + stream.minX * drawn.width,
                                                        y: origin.y + stream.minY * drawn.height)
            Color.black
                .frame(width: box.width, height: box.height)
                .overlay(alignment: .topLeading) {
                    // One view whichever way it draws: changing the gravity
                    // keeps the layer, where swapping views would leave it
                    // black until the next keyframe.
                    VideoLayerView(decoder: panel.decoder,
                                   gravity: fills ? .resizeAspectFill : .resizeAspect)
                        .frame(width: arrived.width, height: arrived.height)
                        // The window's own corner, measured on the Mac and
                        // scaled by the same factor as the picture. Nothing is
                        // drawn — no ring, no second rectangle — so there is one
                        // corner here and it is the one macOS masks the window
                        // into. Square while the stream is cropped, because the
                        // window's corner is not in those pixels.
                        .clipShape(RoundedRectangle(cornerRadius: stream == MirrorCrop.whole
                                                    ? cornerRadius(of: fills ? box : drawn) : 0,
                                                    style: .continuous))
                        .offset(x: arrivedOrigin.x, y: arrivedOrigin.y)
                }
                .clipped()
        } else {
            PanelContent(compact: true,
                         onPickWindow: onPickWindow,
                         onOpenWindow: onOpenWindow)
                .environmentObject(panel)
                .background {
                    if isPlaceholder {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14),
                                          style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius(of: box), style: .continuous))
        }
    }

    /// The largest box with the window's shape that fits the space allowed.
    ///
    /// Nil until the width has been measured, and a plain fill for a pane sent
    /// as characters — text has no shape of its own to honour, and reflows into
    /// whatever box it is given.
    ///
    /// Of the *window*, at every zoom, which is what keeps the band from
    /// changing shape as somebody pinches: the box is the window's proportions
    /// and the zoom happens inside it.
    private var fitted: CGSize? {
        guard available > 0 else { return nil }
        guard let aspect = panel.pictureAspect, aspect > 0 else {
            // A pane sent as characters fills what it is given — text has no
            // shape of its own. A placeholder does not: it is one glyph, one
            // sentence and at most one button, and stretching that over the
            // full stage is how the screen ended up with two dark rectangles
            // the same size and no way to tell them apart.
            let height = isPlaceholder ? min(Metric.stagePlaceholder, maxHeight) : maxHeight
            return CGSize(width: available, height: height)
        }
        let byWidth = CGSize(width: available, height: available / aspect)
        guard byWidth.height > maxHeight else {
            return fillsHeight ? CGSize(width: available, height: maxHeight) : byWidth
        }
        // Taller than it is allowed to be, so the height decides and the band
        // is narrower than the screen. Narrower is the honest answer: the
        // alternative is cutting the top and bottom off a tall window.
        return CGSize(width: maxHeight * aspect, height: maxHeight)
    }

    /// The measured fraction, in the points this panel is drawn at.
    private func cornerRadius(of box: CGSize?) -> CGFloat {
        guard let box, let fraction = panel.cornerFraction, fraction > 0 else { return 0 }
        return min(CGFloat(fraction) * box.width, box.height / 2)
    }

    private func settle(_ box: CGSize?) {
        measure(box)
        publishViewport()
    }

    private func measure(_ box: CGSize?) {
        guard let box, box.width > 0 else { return }
        mirror.card = box
        // The window, not the frames: past 3x the frames are a crop of it, and
        // every fraction on `MirrorState` is a fraction of the window.
        mirror.picture = panel.windowSize ?? .zero
    }

    // MARK: - What the Mac is asked for

    private struct Settled: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        /// The band's own size, so a drag of the handle above the pad is
        /// settled too — once, after it stops.
        var card: CGSize
        var fitBox: CGSize
        var fitsWindow: Bool
    }

    private var fitBox: CGSize { CGSize(width: available, height: maxHeight) }

    /// The region on screen, quantised, so a pinch does not ask the Mac for
    /// something new on every frame of itself.
    private var settled: Settled {
        let region = mirror.focus.region(card: mirror.card, picture: mirror.picture)
        func step(_ value: CGFloat) -> Int { Int((value * 40).rounded()) }
        return Settled(x: step(region.minX), y: step(region.minY),
                       width: step(region.width), height: step(region.height),
                       card: mirror.card, fitBox: fitBox, fitsWindow: fitsWindow)
    }

    private func publishCrop() {
        let region = mirror.focus.region(card: mirror.card, picture: mirror.picture)
        guard let crop = MirrorCrop.wanted(showing: region, streaming: panel.streamCrop) else {
            return
        }
        panel.setCrop(crop)
    }

    /// The box of pixels the Mac is asked to encode into: the band, times how
    /// far the pad has pinched, in whole steps — so a window that arrives
    /// downscaled to tile size at rest arrives at its own resolution when
    /// somebody is reading it.
    private func publishViewport() {
        // Use the offered area, independently of arriving frame dimensions.
        // A fitted picture can cross a pixel step as the codec rounds its
        // aspect, feeding a different viewport back on every arriving frame.
        let box = fitBox
        guard box.width > 0, box.height > 0 else { return }
        guard panel.streamCrop == MirrorCrop.whole else {
            panel.setViewport(points: box)
            return
        }
        let step = CGFloat(min(max(Int(mirror.focus.zoom.rounded()), 1), 3))
        panel.setViewport(points: CGSize(width: box.width * step,
                                         height: box.height * step))
    }
}


/// Everything about the link, in one line, above the picture rather than on it.
///
/// Small on purpose, and smaller still when there is nothing to say. Connected,
/// approved and running, it is a coloured dot and a round trip in
/// milliseconds — the two facts that change — and the Mac's name is left out,
/// because the picture below it is a better answer to "which Mac" than its
/// name is. Anything else about the link is a sentence, and gets one.
///
/// The number carries its unit. It was a bare integer, on the reasoning that
/// the two facts worth having are the colour and the trend — but the colour
/// only means anything once you know what is being counted, and an orange
/// `138` on its own is a number somebody has to guess at. `138ms` is the same
/// glance and the whole fact, for the width of two characters.
///
/// The controls are glyphs with no disc behind them and a tap target wider
/// than they are. There is no expand button: the picture opens itself.
private struct StatusLine: View {
    @EnvironmentObject private var client: NimletClient
    @EnvironmentObject private var listen: ListenClient
    let onSettings: () -> Void
    /// Present only when the mirror is off and there is a Mac to turn it back
    /// on for.
    var onShowPanel: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            if isRoutine {
                if let rtt = client.roundTripMillis {
                    Text("\(Int(rtt.rounded()))ms")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(rtt < 25 ? .white.opacity(0.4)
                                         : rtt < 60 ? Palette.caution.opacity(0.75)
                                         : Palette.attention)
                        .accessibilityLabel("Round trip \(Int(rtt.rounded())) milliseconds")
                }
            } else {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // A failed delivery is worth a mark; a successful one is not worth
            // a pixel, and used to get one.
            if let receipt = client.lastReceipt, !receipt.ok {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.attention)
                    .accessibilityLabel("Last delivery to \(receipt.targetName) failed: \(receipt.message)")
            }
            Spacer(minLength: 8)
            if listen.isOn || (client.state.isConnected && client.status?.deviceApproved == true) {
                glyph("headphones", tint: listenTint, action: toggleListening)
                    .accessibilityLabel(listen.isOn ? "Stop listening to your Mac" : "Listen to your Mac")
                    .accessibilityAddTraits(listen.isOn ? .isSelected : [])
                    .accessibilityValue(listen.statusDescription)
            }
            if let onShowPanel {
                glyph("rectangle.inset.filled.on.rectangle", action: onShowPanel)
                    .accessibilityLabel("Show the mirror of the focused pane")
            }
            glyph("gearshape", action: onSettings)
                .accessibilityLabel("Settings")
        }
        // 44pt of touchable height, 26 of laid-out one: the glyphs keep their
        // small, quiet size, the thing your thumb has to find is the size
        // Apple asks for, and the 18pt of difference hangs off the top and
        // bottom of the line without pushing anything away from it. It was
        // laid out at its full 44 before, which put nine points of nothing
        // between the line and the picture at each end and made them read as
        // two things on the screen rather than one.
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection: \(label)")
    }

    /// Nothing to report beyond the dot and the number.
    private var isRoutine: Bool {
        guard case .connected = client.state else { return false }
        return client.status?.deviceApproved != false && client.status?.injectionPaused != true
    }

    /// Wider than the glyph, the height of the line, and invisible. A disc
    /// behind each of these was two more shapes on a screen that is mostly
    /// one picture.
    private func glyph(_ symbol: String,
                       tint: Color = .white.opacity(0.45),
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }

    /// Off, on and waiting, in that order — and the third state is the one worth
    /// having. A link that has gone quiet while listening is switched on looks
    /// exactly like a Mac that is not playing anything, and the difference
    /// between those two is the whole question you are asking when you look at
    /// this glyph.
    private var listenTint: Color {
        guard listen.isOn else { return .white.opacity(0.45) }
        return listen.isPlaying ? .green : Palette.caution
    }

    private func toggleListening() {
        Haptics.click()
        listen.toggle(control: client)
    }

    private var dotColor: Color {
        switch client.state {
        case .connected:
            if client.status?.deviceApproved == false { return .yellow }
            return client.status?.injectionPaused == true ? .yellow : .green
        case .connecting, .browsing: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var label: String {
        switch client.state {
        case .idle: return "Idle"
        case .browsing: return client.hosts.isEmpty ? "Looking for your Mac…" : "Choose a Mac"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name):
            if client.status?.deviceApproved == false { return "\(name) — waiting for approval" }
            return client.status?.injectionPaused == true ? "\(name) — paused" : name
        case .failed(let message): return message
        }
    }
}


// MARK: - Dictation

/// What the microphone is hearing, in the console's own place.
///
/// This was a card floating over the trackpad with its hit testing switched
/// off — a separate surface, at a separate width, obscuring the one thing it
/// was not about. It is the same band as the composer now, because it is the
/// same question: what is about to be sent, and to whom.
private struct DictationConsole: View {
    @EnvironmentObject private var voice: VoiceCapture
    @AppStorage(DictationLanguage.key) private var language = ""
    /// False until the microphone is actually open, and again while it
    /// restarts in another language: a transcript that does not exist yet
    /// cannot be sent.
    let canSend: Bool
    let onSend: () -> Void
    let onDiscard: () -> Void
    let onLanguage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            meter

            Text(transcript)
                .font(.callout)
                .foregroundStyle(.white.opacity(voice.partialText.isEmpty ? 0.5 : 0.92))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)

            if let warning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Color.white.opacity(0.09), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel("Discard this recording")

                languageMenu

                Spacer(minLength: 0)

                Button(action: onSend) {
                    Label("Send", systemImage: "arrow.up")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Color.accentColor.opacity(canSend ? 1 : 0.3), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(canSend ? 1 : 0.5))
                .disabled(!canSend)
                .accessibilityLabel("Send what was said")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        )
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictating")
        .accessibilityValue(voice.partialText.isEmpty ? "listening" : voice.partialText)
    }

    /// The language being listened for, and the way to change it, where the
    /// wrong-language transcript is — that is the moment it gets noticed.
    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: Binding(get: { language }, set: onLanguage)) {
                ForEach(DictationLanguage.options) { option in
                    Text(option.name).tag(option.id)
                }
            }
        } label: {
            Label(DictationLanguage.option(for: language).short, systemImage: "globe")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.white.opacity(0.09), in: Capsule())
                .contentShape(Capsule())
        }
        .foregroundStyle(.white.opacity(0.75))
        .accessibilityLabel("Dictation language")
        .accessibilityValue(DictationLanguage.option(for: language).name)
    }

    private var transcript: String {
        if !voice.partialText.isEmpty { return voice.partialText }
        return voice.isRecording ? "Listening…" : "Getting ready…"
    }

    private var warning: String? {
        if voice.hitDurationLimit { return "That's as long as one recording goes" }
        return voice.errorMessage
    }

    private var meter: some View {
        HStack(spacing: 3) {
            ForEach(0..<18, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.08), value: voice.level)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // Cheap symmetric envelope so the meter reads as a voice, not a bar chart.
        let distanceFromCenter = abs(Double(index) - 8.5) / 8.5
        let envelope = 1 - distanceFromCenter * 0.75
        let base = 4.0
        return CGFloat(base + Double(voice.level) * 32 * envelope)
    }
}

// MARK: - Overlays

/// Where a long transcript is approved before it is pressed into a shell.
private struct TranscriptReview: View {
    let draft: TranscriptDraft
    let onSend: (String, Bool) -> Void
    @State private var text: String
    /// Off by default, even for a target that normally presses Return.
    /// Everything that reaches this sheet is long enough to have been worth
    /// stopping for, and the one irreversible part of sending it is the Return
    /// at the end — so that part is opted into here rather than inherited.
    @State private var submit = false
    @Environment(\.dismiss) private var dismiss

    init(draft: TranscriptDraft, onSend: @escaping (String, Bool) -> Void) {
        self.draft = draft
        self.onSend = onSend
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Transcript")
                    .accessibilityHint("Edit before sending")
                Text("\(text.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Press Return after sending", isOn: $submit)
                    .disabled(!draft.allowAutoSubmit)
                    .font(.callout)
                Text(draft.allowAutoSubmit
                     ? "Off, so the text lands in the prompt and you decide when it runs."
                     : "Off and locked: \(draft.targetName) is set on your Mac to never press Return.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .navigationTitle("Send to \(draft.targetName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(text, submit && draft.allowAutoSubmit)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ToastView: View {
    @EnvironmentObject private var client: NimletClient

    var body: some View {
        if let toast = client.toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.25), value: client.toast)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
