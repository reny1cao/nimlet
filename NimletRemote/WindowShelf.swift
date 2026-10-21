import SwiftUI

/// A horizontal window picker that floats above the Dock without changing the mirror's size.
struct WindowShelf: View {
    static func height(hasWindows: Bool) -> CGFloat { hasWindows ? 217 : 158 }
    let target: NimletTarget
    let onClose: () -> Void
    @EnvironmentObject private var client: NimletClient

    private let cardWidth: CGFloat = 148
    private let thumbnailHeight: CGFloat = 92
    private var roster: NimletClient.WindowRoster? { client.windowRoster(for: target.id) }
    private var windows: [MacWindow] { roster?.windows ?? [] }
    private var running: RunningMacApp? { target.appReference.flatMap { client.runningApp(for: $0) } }
    private var usableRoster: Bool { running != nil && roster?.appIdentity == running?.identity }
    private var isFetching: Bool { client.fetchingWindowsFor == target.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if windows.isEmpty {
                HStack(spacing: 12) {
                    Text(isFetching ? "Reading windows…" : emptyMessage)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if !isFetching {
                        Button("Open") { perform(.reopen) }
                            .font(.caption.weight(.semibold)).disabled(!client.canManageApps)
                    }
                }.padding(.horizontal, 14).frame(minHeight: 54)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(windows) { window in
                                WindowCard(window: window, title: titles[window.id] ?? window.displayTitle,
                                    preview: client.preview(of: window),
                                    selected: isSelected(window),
                                    width: cardWidth, thumbnailHeight: thumbnailHeight,
                                    canClose: client.canManageApps && usableRoster && window.canClose && !window.isMinimized,
                                    onTap: { pick(window) },
                                    onClose: { perform(.closeWindow, window: window, identity: roster?.appIdentity) })
                                .id(window.id)
                            }
                        }.padding(.horizontal, 14)
                    }
                    .frame(height: thumbnailHeight + 21)
                    .defaultScrollAnchor(.leading)
                    .fadedScrollEdges()
                    // The cards stay in the order the windows were opened, so
                    // the one being shown can be anywhere in the row. Brought
                    // into view rather than moved to the front.
                    .onAppear { reveal(selectedID, with: proxy, animated: false) }
                    .onChange(of: selectedID) { _, id in reveal(id, with: proxy, animated: true) }
                }
            }
            HStack {
                Button {
                    Haptics.click()
                    client.focusWindow(nil, for: target.id)
                    onClose()
                } label: {
                    Label("Follow app", systemImage: target.pinnedWindowID == nil ? "checkmark" : "rectangle.on.rectangle")
                }
                .disabled(!client.state.isConnected)
                .accessibilityHint("Follow whichever window this app brings to the front")
                Spacer()
                if !usableRoster && !windows.isEmpty && client.supportsAppManagement {
                    Text("Refresh windows").foregroundStyle(.secondary)
                }
            }
            .font(.caption).padding(.horizontal, 14).frame(height: 28)
        }
        .padding(.vertical, 10)
        .frame(height: Self.height(hasWindows: !windows.isEmpty), alignment: .top)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityIdentifier("window-shelf")
        .task(id: target.id) { refresh() }
        .onChange(of: client.state.isConnected) { _, connected in if connected { refresh() } }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(target.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(windows.count == 1 ? "1 window" : "\(windows.count) windows")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button("Quit", role: .destructive) { perform(.quit, identity: running?.identity) }
                .font(.system(size: 12, weight: .medium)).frame(minWidth: 40, minHeight: 40)
                .accessibilityLabel("Quit \(target.name)")
                .disabled(!client.canManageApps || running == nil)
            Button { refresh(); Haptics.secondaryClick() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 36, height: 40)
            }.accessibilityLabel("Refresh windows").disabled(!client.state.isConnected)
            Button(action: onClose) {
                Image(systemName: "chevron.down").frame(width: 36, height: 40)
            }.accessibilityLabel("Dismiss window picker")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 14)
    }

    private var emptyMessage: String {
        if let note = roster?.note { return note.hasPrefix("is ") || note.hasPrefix("isn't ") ? "\(target.name) \(note)" : note }
        return "No windows are open."
    }

    /// The card for the window the mirror is showing: the pinned one, or the
    /// one in front when the target follows its app.
    private func isSelected(_ window: MacWindow) -> Bool {
        window.isPinned || (target.pinnedWindowID == nil && window.isFrontmost)
    }

    private var selectedID: UInt32? { windows.first(where: isSelected)?.id }

    /// Titles that tell the cards apart. An app whose windows all carry its own
    /// name — four cards reading "ChatGPT" — gets them numbered, in the row's
    /// order, which does not change when one is brought forward.
    private var titles: [UInt32: String] {
        let counts: [String: Int] = Dictionary(windows.map { ($0.displayTitle, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        var titles: [UInt32: String] = [:]
        for window in windows where counts[window.displayTitle, default: 0] > 1 {
            let index = seen[window.displayTitle, default: 0] + 1
            seen[window.displayTitle] = index
            titles[window.id] = "\(window.displayTitle) \(index)"
        }
        return titles
    }

    private func reveal(_ id: UInt32?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            // After the row's first layout, or there is nothing to scroll yet.
            Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func refresh() { client.requestAppState(); client.requestWindows(for: target.id) }
    private func pick(_ window: MacWindow) {
        guard window.canRaise else { Haptics.attention(); return }
        Haptics.click()
        if client.supportsAppManagement {
            // Said rather than swallowed: a tap that only refreshed the list
            // looked exactly like a switch that did not work.
            guard usableRoster else { client.note("Checking \(target.name)'s windows — tap again"); refresh(); return }
            perform(window.isMinimized ? .restoreWindow : .focusWindow, window: window, identity: roster?.appIdentity)
        } else {
            if window.isMinimized { client.openWindow(window.id, for: target.id) }
            else { client.focusWindow(window.id, for: target.id) }
            onClose()
        }
    }

    private func perform(_ action: AppCommand.Action, window: MacWindow? = nil, identity: AppInstanceIdentity? = nil) {
        guard let ref = target.appReference else { return }
        // Close is sent to this exact window. The Mac's own save dialog protects unsaved work.
        if client.performAppAction(action, app: ref, identity: identity ?? running?.identity,
                                   targetID: target.id, windowID: window?.id) { onClose() }
    }
}

private struct WindowCard: View {
    let window: MacWindow
    let title: String
    let preview: UIImage?
    let selected: Bool
    let width: CGFloat
    let thumbnailHeight: CGFloat
    let canClose: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    thumbnail
                    Text(title)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(window.canRaise ? 0.9 : 0.4))
                        .frame(width: width, height: 15, alignment: .leading)
                }.frame(width: width).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!window.canRaise)
            .accessibilityLabel(title)
            .accessibilityValue(window.isMinimized ? "Minimized" : (selected ? "Selected" : ""))
            .accessibilityHint("Show this window on your Mac and mirror it here")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(canClose ? 0.95 : 0.25))
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.75), in: Circle())
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canClose)
            .accessibilityLabel("Close \(title)")
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05))
            if let preview {
                Image(uiImage: preview).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    .frame(width: width, height: thumbnailHeight).clipped()
                    .opacity(window.isMinimized ? 0.5 : 1)
            } else {
                Image(systemName: window.isMinimized ? "rectangle.arrowtriangle.2.inward" : "macwindow")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: width, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if selected || window.isMinimized {
                Image(systemName: window.isMinimized ? "arrow.up.left.and.arrow.down.right" : "checkmark")
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(selected ? Color.accentColor : Palette.unavailableMark, in: Circle()).padding(5)
            }
        }
    }
}
