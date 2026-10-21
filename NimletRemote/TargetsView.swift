import SwiftUI

/// The target list, editable from the phone.
///
/// The Mac still owns it — every change here is a request, and what comes back
/// is the Mac's new list rather than this screen's guess at it. That is not
/// ceremony: the Mac is the only place that can tell whether a pane still
/// exists or an app is installed, and a phone that edited its own copy would be
/// quietly overwritten the next time anything else changed.
struct TargetsView: View {
    @EnvironmentObject private var client: NimletClient
    @ObservedObject var replies: QuickReplyStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NimletTarget?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only explicit favorites are ordered and persisted.
                    ForEach(client.targets.filter { !$0.isProvisional }) { target in
                        Button { editing = target } label: {
                            row(target).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Remove favorite", role: .destructive) { client.removeTarget(target.id) }
                        }
                    }
                    .onMove { source, destination in
                        var ids = client.targets.filter { !$0.isProvisional }.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        client.reorderTargets(ids)
                    }
                } footer: {
                    Text("Tap one to rename it, point it at another pane, or stop Nimlet "
                         + "pressing Return on it.")
                }

                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Add a target", systemImage: "plus.circle.fill")
                    }
                    .disabled(!client.state.isConnected)
                }
            }
            .navigationTitle("Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { target in
                TargetEditor(target: target, replies: replies)
            }
            // The same picker the dock's `+` opens, minus its way back here.
            .sheet(isPresented: $adding) { AddTargetSheet() }
            // So every pane target can be described by the session and command
            // a person recognises, rather than by the id Nimlet stores.
            .task { client.requestPanes() }
        }
    }

    private func row(_ target: NimletTarget) -> some View {
        let missing = client.unresolvedTargetIDs.contains(target.id)
        return HStack(spacing: 12) {
            // The app's own icon, the same one the dock now wears — except
            // where the target is broken, which is the one thing this row has
            // to say before it says which app it is.
            if let icon = client.icon(for: target), !missing {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: missing ? "exclamationmark.triangle" : target.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 26)
                    .foregroundStyle(missing ? .orange : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name).font(.body)
                    if !target.allowAutoSubmit {
                        badge("no Return")
                    }
                }
                if let detail = detail(of: target, missing: missing) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(missing ? .orange : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.name)
        .accessibilityValue((detail(of: target, missing: missing) ?? spokenKind(of: target))
                            + (target.allowAutoSubmit ? "" : ", never presses Return"))
        .accessibilityHint("Opens this target's settings")
        .accessibilityAddTraits(.isButton)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2), in: Capsule())
    }

    /// What this target is, in the words the user would use for it.
    ///
    /// It used to be whatever Nimlet stores — `%0`, `com.apple.Terminal` — which
    /// is the one thing that identifies a target without describing it. A pane
    /// id is a handle, not a name: two of them tell you nothing about which
    /// window either one is. The session, window and running command do.
    private func detail(of target: NimletTarget, missing: Bool) -> String? {
        switch target.kind {
        case .tmux:
            // Named as a thing to fix, not as an error code: the pane is
            // usually one `tmux new-session` away.
            if missing { return "its pane has closed — pick another" }
            guard let pane = client.pane(for: target) else { return nil }
            // The window it is in and what is running there. The path is left
            // to the pane picker: on one line it is the part most likely to be
            // the same for every pane you own.
            return "\(pane.spec) · \(pane.command)"
        case .app:
            // Nothing true left to say. An app target is named after its app,
            // and repeating "Mac app" down four rows is a column of filler
            // where the eye expects a difference.
            return nil
        case .frontmost:
            return "whatever has focus"
        }
    }

    /// Only spoken, where the icon that carries this silently is not available.
    private func spokenKind(of target: NimletTarget) -> String {
        switch target.kind {
        case .app: return "Mac app"
        case .tmux: return "tmux pane"
        case .frontmost: return "whatever has focus"
        }
    }
}

// MARK: - Edit

private struct TargetEditor: View {
    let target: NimletTarget
    @ObservedObject var replies: QuickReplyStore
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NimletTarget
    @State private var phrases: [String]
    @State private var confirmingRemoval = false
    @State private var repicking = false

    init(target: NimletTarget, replies: QuickReplyStore) {
        self.target = target
        _replies = ObservedObject(wrappedValue: replies)
        _draft = State(initialValue: target)
        _phrases = State(initialValue: replies.phrases(for: target.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $draft.name)
                        .autocorrectionDisabled()
                }

                if draft.kind == .tmux {
                    Section {
                        LabeledContent("Pane") {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(paneDescription)
                                if let id = draft.tmuxTarget {
                                    // The stored handle, kept here and nowhere
                                    // else: this is the screen where you are
                                    // changing what it points at.
                                    Text(id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Point at another pane") {
                            client.requestPanes()
                            repicking = true
                        }
                    } footer: {
                        Text(client.unresolvedTargetIDs.contains(target.id)
                             ? "This pane has closed. Anything sent here goes nowhere until you pick another."
                             : "Only the pane id is stored, so it survives other panes closing while "
                               + "the session and window numbers shift around it.")
                    }
                } else if draft.kind == .app {
                    Section {
                        LabeledContent("App", value: draft.bundleID ?? "—")
                            .font(.callout)
                    } footer: {
                        Text("Raises this app's window, then pastes. Change which app it is on "
                             + "the Mac.")
                    }
                }

                Section {
                    Picker("Buttons", selection: $draft.profileID) {
                        Text("Automatic").tag(String?.none)
                        ForEach(profileChoices) { profile in
                            Text(profile.name).tag(String?.some(profile.id))
                        }
                    }
                    if draft.kind == .app {
                        Button("Read this app's menus again") { client.refreshMenu(for: draft) }
                    }
                    ForEach(resolvedProfile.actions) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(action.label, systemImage: action.symbol)
                                    .font(.callout)
                                Spacer()
                                Text(chordLabel(action))
                                    .font(.callout.monospaced())
                                    .foregroundStyle(action.kind == .key && action.chord == nil
                                                     ? .orange : .secondary)
                            }
                            if let note = action.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text(automaticFooter)
                }

                Section {
                    ForEach(phrases.indices, id: \.self) { index in
                        TextField("Phrase \(index + 1)", text: $phrases[index])
                            .autocorrectionDisabled()
                            .accessibilityLabel("Quick reply \(index + 1)")
                    }
                } header: {
                    Text("Quick replies")
                } footer: {
                    Text("Kept on this phone, not on the Mac — the Mac replaces its target "
                         + "list wholesale, and a phrase you typed must not go with it.")
                }

                Section {
                    Toggle("Press Return after sending", isOn: $draft.submitOnSend)
                        .disabled(!draft.allowAutoSubmit)
                    Toggle("Never press Return on this target", isOn: neverSubmit)
                } footer: {
                    Text("The second one is policy: it wins over the switch above and over any "
                         + "per-message request. Text still arrives — you press Return yourself.")
                }

                Section {
                    Button("Remove target", role: .destructive) { confirmingRemoval = true }
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $repicking) {
                PanePicker { pane in
                    draft.tmuxTarget = pane.id
                    repicking = false
                }
            }
            .confirmationDialog("Remove \(target.name)?",
                                isPresented: $confirmingRemoval,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    client.removeTarget(target.id)
                    dismiss()
                }
            } message: {
                Text("The pane or app is untouched. Only Nimlet forgets about it.")
            }
        }
    }

    /// An unbound action is shown here and nowhere else: the phone's grid has
    /// no room for a button that cannot do anything, but the settings screen is
    /// exactly where you would look to find out why it is missing.
    private func chordLabel(_ action: ShortcutAction) -> String {
        if action.kind == .dictate { return "this phone" }
        return action.chord?.display ?? "not set"
    }

    /// Asked of the client rather than resolved again here, so the settings
    /// screen and the dock can never name different sets for one target.
    private var resolvedProfile: ShortcutProfile { client.shortcuts(for: draft) }

    /// Only the sets this kind of target could use: a pane cannot receive a ⌘
    /// key and a window cannot receive `tmux send-keys`. A target already
    /// pinned to something from the other list keeps it in the menu, so opening
    /// this screen cannot silently repoint it.
    private var profileChoices: [ShortcutProfile] {
        let choices = ShortcutProfiles.choices(for: draft.kind)
        guard let pinned = ShortcutProfiles.profile(id: draft.profileID),
              !choices.contains(where: { $0.id == pinned.id }) else { return choices }
        return choices + [pinned]
    }

    private var automaticFooter: String {
        guard draft.profileID == nil else {
            return draft.kind == .tmux
                ? "Chosen by hand, so it stays this set whatever the pane is running."
                : "Chosen by hand, so it stays this set."
        }
        switch draft.kind {
        case .tmux:
            return "Automatic reads what is running in the pane right now — \(automaticSummary). "
                + "These tools rebind their own keys between releases; pick a set by hand if one is wrong."
        case .app:
            // What is actually in use, which for an app is usually what its own
            // menu bar said. "Why are these the buttons?" is the question this
            // screen exists to answer, and a guess described as a reading — or
            // the reverse — is the one answer that is worse than none.
            if let reading = client.menuReading(for: draft) {
                switch reading.outcome {
                case .read:
                    return reading.note + " Every key here is the app's own, so a rebound one is "
                        + "the rebound one. Pick a set by hand to use Nimlet's instead."
                case .notRunning, .unreadable, .nothingUseful:
                    return reading.note + " Until then these are Nimlet's own: \(curatedName)."
                }
            }
            return "Reading \(draft.name)'s menus… until they arrive these are Nimlet's own: "
                + "\(curatedName)."
        case .frontmost:
            return "Whatever has focus could be any window, so this is the set that is true of "
                + "all of them."
        }
    }

    /// The set Nimlet would pick on its own, named so the footer can say what it
    /// is falling back to.
    private var curatedName: String {
        ShortcutProfiles.resolved(for: draft, paneCommand: client.pane(for: draft)?.command).name
    }

    private var automaticSummary: String {
        guard let command = client.pane(for: draft)?.command else {
            return "its pane isn't reporting one"
        }
        return "\(command), so \(ShortcutProfiles.guess(forCommand: command).name)"
    }

    private var paneDescription: String {
        guard let pane = client.pane(for: draft) else {
            return client.unresolvedTargetIDs.contains(target.id) ? "closed" : "—"
        }
        return "\(pane.spec) · \(pane.command)"
    }

    /// The policy switch reads the inverse of the stored flag, because "never"
    /// is the thing being turned on.
    private var neverSubmit: Binding<Bool> {
        Binding(get: { !draft.allowAutoSubmit },
                set: { never in
                    draft.allowAutoSubmit = !never
                    // Turning the policy on has to turn the preference off too,
                    // or the target keeps a "yes" that can never be honoured and
                    // comes back to life if the policy is ever lifted.
                    if never { draft.submitOnSend = false }
                })
    }

    private func save() {
        replies.setPhrases(phrases, for: target.id)
        var edited = draft
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited != target { client.updateTarget(edited) }
        dismiss()
    }
}

// MARK: - Add

/// The typed path, kept for what the picker cannot offer: an app that lives
/// outside the Mac's applications folders, and so is in no scan of them.
///
/// Not private, because the picker presents it — it is the one row at the
/// bottom of that sheet rather than the way anybody is expected to start.
struct TargetAdder: View {
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss
    /// An app, because the panes are a tap each in the picker this now hangs
    /// off, and an identifier typed by hand is almost always an app's.
    @State private var kind: NimletTarget.Kind = .app
    @State private var name = ""
    @State private var pane: TmuxPane?
    @State private var bundleID = ""
    @State private var allowAutoSubmit = true

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return kind == .tmux ? pane != nil : !bundleID.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What kind") {
                    Picker("Kind", selection: $kind) {
                        Text("tmux pane").tag(NimletTarget.Kind.tmux)
                        Text("Mac app").tag(NimletTarget.Kind.app)
                    }
                    .pickerStyle(.segmented)
                    Text(kind == .tmux
                         ? "Arrives whether or not its window is visible."
                         : "Raises its window first, taking focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if kind == .tmux {
                    Section {
                        if client.isFetchingPanes {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Asking the Mac…").foregroundStyle(.secondary)
                            }
                            StalledHint(after: 10,
                                        message: "Taking longer than usual. The Mac may be busy, or the link may have dropped.",
                                        actionTitle: "Ask again") { client.requestPanes() }
                        } else if client.panes.isEmpty {
                            Text(client.status?.tmuxAvailable == false
                                 ? "tmux isn't installed on that Mac, so there are no panes to pick."
                                 : "tmux is installed, but no panes are running.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(client.panes) { candidate in
                            Button {
                                pane = candidate
                                if name.isEmpty { name = candidate.command }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(candidate.command)  \(candidate.spec)")
                                            .font(.callout)
                                        Text(candidate.shortPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if pane?.id == candidate.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                // Without this the row is only tappable where
                                // its text is, so the right half of a 44pt row
                                // does nothing — which reads as the app
                                // ignoring you rather than as a dead area.
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(pane?.id == candidate.id ? [.isButton, .isSelected] : .isButton)
                        }
                        Button("Refresh panes") { client.requestPanes() }
                    } header: {
                        Text("Pick a pane")
                    }
                } else {
                    Section {
                        TextField("com.apple.Terminal", text: $bundleID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        Text("Bundle identifier")
                    } footer: {
                        Text("For an app the picker doesn't list. The Mac refuses an "
                             + "identifier it can't find installed.")
                    }
                }

                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    Toggle("Never press Return on this target", isOn: Binding(
                        get: { !allowAutoSubmit },
                        set: { allowAutoSubmit = !$0 }))
                } footer: {
                    Text("Turn that on for a shell. It is the only thing standing between a "
                         + "dictated sentence and a command running unattended.")
                }
            }
            .navigationTitle("Add a target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
        }
    }

    private func add() {
        let target = NimletTarget(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                kind: kind,
                                bundleID: kind == .app ? bundleID : nil,
                                tmuxTarget: kind == .tmux ? pane?.id : nil,
                                submitOnSend: allowAutoSubmit,
                                allowAutoSubmit: allowAutoSubmit,
                                symbol: kind == .tmux ? "terminal" : "app")
        client.addTarget(target)
        dismiss()
    }
}

// MARK: - Pane picker

private struct PanePicker: View {
    let onPick: (TmuxPane) -> Void
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if client.isFetchingPanes {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking the Mac…").foregroundStyle(.secondary)
                    }
                    StalledHint(after: 10,
                                message: "Taking longer than usual. The Mac may be busy, or the link may have dropped.",
                                actionTitle: "Ask again") { client.requestPanes() }
                } else if client.panes.isEmpty {
                    Text("No panes are running.").foregroundStyle(.secondary)
                }
                ForEach(client.panes) { pane in
                    Button { onPick(pane) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pane.command)  \(pane.spec)").font(.callout)
                            Text(pane.shortPath).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Refresh panes") { client.requestPanes() }
            }
            .navigationTitle("Pick a pane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
