import SwiftUI
import UniformTypeIdentifiers

/// Tap switches apps; another tap on the focused app opens its horizontal picker.
/// Long press edits the phone's Dock without changing the running app's windows.
struct TargetDock: View {
    @Binding var fanOut: FanOut
    @Binding var shelfTargetID: String?
    let onManage: () -> Void
    @EnvironmentObject private var client: NimletClient
    @AppStorage("mice.dock.showNames") private var showsNames = true
    @State private var isEditing = false
    @State private var dragging: String?
    @ScaledMetric(relativeTo: .caption) private var tileCeiling = DockMetrics.ceiling
    @ScaledMetric(relativeTo: .caption) private var tileFloor = DockMetrics.floor
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 14
    private let endMargin: CGFloat = 20
    private var labelSpace: CGFloat { showsNames ? labelHeight + 5 : 0 }

    var body: some View {
        GeometryReader { geometry in
            let targets = client.dockTargets
            let row = DockMetrics.layout(tiles: max(1, targets.count),
                in: max(0, geometry.size.width - endMargin * 2 - 58 - CGFloat(targets.count) * 8),
                ceiling: tileCeiling, floor: tileFloor)
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: row.spacing) {
                        ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                            DockTile(target: target, index: index, side: row.side,
                                showsNames: showsNames, labelHeight: labelHeight,
                                fanOut: $fanOut, shelfTargetID: $shelfTargetID,
                                isEditing: isEditing,
                                onEdit: beginEditing, onRemove: {
                                    withAnimation(.spring(duration: 0.24)) { client.removeFromDock(target) }
                                    if shelfTargetID == target.id { shelfTargetID = nil }
                                    fanOut.targetIDs.remove(target.id)
                                })
                                .onDrag(if: isEditing) {
                                    dragging = target.id
                                    Haptics.dragStart()
                                    return NSItemProvider(object: target.id as NSString)
                                }
                                .onDrop(if: isEditing, of: [.text], delegate:
                                    DockDropDelegate(target: target, dragging: $dragging, client: client))
                        }
                        if targets.isEmpty {
                            Text("Add apps from All")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(height: tileCeiling + labelSpace)
                        }
                    }
                    // Space belongs inside the scroll content, including the remove badges.
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, endMargin, for: .scrollContent)
                .defaultScrollAnchor(.leading)
                .fadedScrollEdges()
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 30)
                Button {
                    if isEditing { isEditing = false; dragging = nil; Haptics.click() }
                    else { onManage() }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: isEditing ? "checkmark" : "square.grid.2x2")
                            .font(.system(size: 20, weight: .medium)).frame(width: 44, height: tileCeiling)
                        if showsNames {
                            Text(isEditing ? "Done" : "All")
                                .font(.system(size: 10, weight: .medium)).frame(height: labelHeight)
                        }
                    }
                    .foregroundStyle(isEditing ? Color.accentColor : Color.white.opacity(0.6))
                    .frame(width: 57).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEditing ? "Done editing Dock" : "All apps")
                .accessibilityAction(named: "Edit Dock", beginEditing)
            }
        }
        .frame(height: tileCeiling + labelSpace + 26)
        .background(Color(white: 0.16), in: Capsule())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, Metric.dockInset - Metric.gutter)
        .animation(.easeOut(duration: 0.2), value: showsNames)
        .onChange(of: client.targets.map(\.id)) { _, _ in dragging = nil }
        .onChange(of: client.state.isConnected) { _, connected in
            if !connected { isEditing = false; dragging = nil }
        }
    }

    private func beginEditing() {
        guard client.state.isConnected else { return }
        shelfTargetID = nil
        fanOut.isActive = false
        isEditing = true
        Haptics.dragStart()
    }
}

private struct DockDropDelegate: DropDelegate {
    let target: NimletTarget
    @Binding var dragging: String?
    let client: NimletClient

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id else { return }
        var order = client.dockTargets.map(\.id)
        guard let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target.id) else { return }
        withAnimation(.spring(duration: 0.22)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            client.reorderDockTargets(order)
        }
        Haptics.secondaryClick()
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private extension View {
    @ViewBuilder func onDrag(if active: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if active { self.onDrag(provider) } else { self }
    }
    @ViewBuilder func onDrop(if active: Bool, of types: [UTType], delegate: DropDelegate) -> some View {
        if active { self.onDrop(of: types, delegate: delegate) } else { self }
    }
}

private struct DockTile: View {
    let target: NimletTarget
    let index: Int
    let side: CGFloat
    let showsNames: Bool
    let labelHeight: CGFloat
    @Binding var fanOut: FanOut
    @Binding var shelfTargetID: String?
    let isEditing: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void
    @EnvironmentObject private var client: NimletClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didHold = false
    @State private var holdTask: Task<Void, Never>?
    @State private var wigglesForward = false
    private var isActive: Bool { client.activeTargetID == target.id }
    private var isSelected: Bool { fanOut.isActive && fanOut.targetIDs.contains(target.id) }
    private var isMissing: Bool { client.unresolvedTargetIDs.contains(target.id) }
    /// The tile's last report — or "waiting" while it has a question or a
    /// permission prompt open, which is newer than anything it reported.
    private var event: AgentEvent? {
        if let waiting = client.pendingApproval(for: target.id) {
            return AgentEvent(targetID: target.id, kind: .waiting, atEpochMillis: waiting.createdAtEpochMillis)
        }
        return client.lastEvent(for: target.id)
    }
    private var iconSide: CGFloat { side - 6 }
    private var runningState: NimletClient.AppRunningState? {
        target.appReference.map { client.appRunningState(for: $0) }
    }
    private var spokenValue: String {
        var parts: [String] = []
        switch runningState {
        case .running: parts.append("Running")
        case .notRunning: parts.append("Not running")
        case .unknown: parts.append("Running state unavailable")
        case nil: break
        }
        if isActive { parts.append("Focused") }
        return parts.joined(separator: ", ")
    }
    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: iconSide * 0.225, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: tapped) {
                VStack(spacing: 5) {
                    artwork.frame(width: side, height: side)
                    if showsNames {
                        Text(target.name)
                            .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(Color.white.opacity(isActive ? 0.95 : 0.6))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(width: side + 8, height: labelHeight)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: side + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(TilePress { pressChanged($0) })
            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(x: -13, y: -16)
                .accessibilityLabel("Remove \(target.name) from Dock")
            } else if target.pinnedWindowID != nil && !fanOut.isActive {
                Image(systemName: "macwindow")
                    .font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 11, height: 11).background(Color.accentColor, in: Circle())
                    .frame(maxWidth: .infinity, alignment: .trailing).offset(y: -2)
            } else if fanOut.isActive {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .rotationEffect(.degrees(isEditing && !reduceMotion
            ? (wigglesForward ? 1.5 : -1.5) * (index.isMultiple(of: 2) ? 1 : -1) : 0))
        // Adding the native drag modifier can remount a tile in edit mode.
        // Start on appearance too, rather than relying on a value-change animation.
        .onAppear { updateJiggle() }
        .onChange(of: isEditing) { _, _ in updateJiggle() }
        .onChange(of: reduceMotion) { _, _ in updateJiggle() }
        .onDisappear { holdTask?.cancel() }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(target.name)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isEditing ? "Drag to move, or remove from Dock" :
            (isActive && target.kind == .app ? "Tap to show windows. Hold to edit Dock." : "Tap to switch. Hold to edit Dock."))
        .accessibilityAction(named: "Edit Dock", onEdit)
    }

    private var artwork: some View {
        ZStack {
            if let image = client.icon(for: target), !isMissing {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: iconSide * client.iconScale(for: target),
                           height: iconSide * client.iconScale(for: target))
            } else {
                iconShape.fill(Color.white.opacity(0.14))
                    .overlay(Image(systemName: isMissing ? "exclamationmark.triangle" : target.symbol)
                        .font(.system(size: SymbolInk.size(of: target.symbol, filling: iconSide, fraction: 0.5)))
                        .foregroundStyle(isMissing ? Palette.attention : .white.opacity(0.9)))
            }
        }
        .frame(width: iconSide, height: iconSide)
        .overlay(iconShape.strokeBorder(isActive || isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.2))
        .overlay(alignment: .bottomLeading) {
            if let runningState, runningState != .notRunning {
                Group {
                    if runningState == .running { Circle().fill(.white) }
                    else { Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1) }
                }
                    .frame(width: 5, height: 5)
                    .padding(2).background(.black.opacity(0.6), in: Circle())
                    .offset(x: -1, y: 1).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if let event {
                AgentIndicator(event: event).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
    }

    // Button press cancellation preserves normal horizontal scrolling.
    private func updateJiggle() {
        guard isEditing && !reduceMotion else {
            withAnimation(.easeOut(duration: 0.14)) { wigglesForward = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)
            .delay(Double(index % 4) * 0.06)) { wigglesForward = true }
    }

    private func pressChanged(_ pressed: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard pressed, !isEditing else { return }
        didHold = false
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            didHold = true
            onEdit()
        }
    }

    private func tapped() {
        holdTask?.cancel()
        holdTask = nil
        if didHold { didHold = false; return }
        guard !isEditing else { return }
        if fanOut.isActive {
            if fanOut.targetIDs.contains(target.id) { fanOut.targetIDs.remove(target.id) }
            else { fanOut.targetIDs.insert(target.id) }
            Haptics.secondaryClick()
        } else if isActive && target.kind == .app {
            Haptics.click()
            withAnimation(.spring(duration: 0.24)) {
                shelfTargetID = shelfTargetID == target.id ? nil : target.id
            }
        } else {
            shelfTargetID = nil
            Haptics.click()
            client.focus(target.id)
        }
    }
}

// MARK: - The running indicator

/// The last state an agent reported, with the age of that report — and nothing
/// at all when it has reported nothing.
///
/// The age is never optional and never hidden once there *is* one. This is a
/// memory of a message, not a live reading — nothing here is re-checked against
/// the Mac — so a state we cannot vouch for must not be drawn as a confident
/// "running".
struct AgentIndicator: View {
    let event: AgentEvent?

    var body: some View {
        if let event {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 3) {
                    dot(for: event.kind)
                    Text(Self.age(of: event, at: context.date))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(height: 7)
            }
        }
        // No `else`. A target with nothing to report draws nothing and takes
        // no space: this is an overlay, so an empty one costs the tile's
        // layout nothing at all.
    }

    @ViewBuilder private func dot(for kind: AgentEvent.Kind) -> some View {
        switch kind {
        case .waiting:
            Circle()
                .fill(Color.yellow)
                .frame(width: 6, height: 6)
                .shadow(color: .yellow.opacity(0.7), radius: 3)
        case .done:
            Circle()
                .strokeBorder(Color.green.opacity(0.9), lineWidth: 2)
                .frame(width: 6, height: 6)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.orange)
        }
    }

    /// How long ago, bucketed once and worded twice.
    ///
    /// The thresholds were written out separately for the label and for
    /// VoiceOver, which meant changing one left the screen and the spoken
    /// description disagreeing about the age of the same event.
    private static func bucket(_ event: AgentEvent, at now: Date) -> (value: Int, unit: Int) {
        let seconds = max(0, now.timeIntervalSince1970 - Double(event.atEpochMillis) / 1000)
        if seconds < 60 { return (Int(seconds), 0) }
        if seconds < 3600 { return (Int(seconds / 60), 1) }
        if seconds < 86_400 { return (Int(seconds / 3600), 2) }
        return (Int(seconds / 86_400), 3)
    }

    static func age(of event: AgentEvent, at now: Date) -> String {
        let (value, unit) = bucket(event, at: now)
        return "\(value)\(["s", "m", "h", "d"][unit])"
    }

    static func spokenAge(of event: AgentEvent) -> String {
        let (value, unit) = bucket(event, at: Date())
        let words = ["seconds", "minutes", "hours", "days"]
        return "\(value) \(words[unit]) ago"
    }
}

/// Reports the button's press state without changing how it looks.
///
/// The whole reason the tile is a button: `isPressed` goes false when the
/// finger lifts, when it slides off, *and* when the scroll view cancels the
/// touch to begin a pan. A gesture cannot see the third one without taking the
/// touch away from the scroll view, which is what stopped the dock scrolling.
private struct TilePress: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPressChanged(pressed) }
    }
}
