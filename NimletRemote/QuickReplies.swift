import PhotosUI
import SwiftUI
import UIKit

/// Which targets the next thing sent goes to.
struct FanOut {
    var isActive = false
    var targetIDs: Set<String> = []
}

/// The three or four phrases you otherwise retype dozens of times a day.
///
/// Kept on the phone rather than on the target: the Mac owns the target list
/// and replaces it wholesale whenever it changes, and a phrase typed here must
/// not disappear with it.
@MainActor
final class QuickReplyStore: ObservableObject {
    static let slots = 4

    /// What is worth tapping on the first day, per kind of thing on the other
    /// end.
    ///
    /// There used to be one list — continue · yes · run the tests · stop —
    /// handed to every target on the machine. Those are four things you say to
    /// a coding agent, and the strip offered them to Safari. The keys beside
    /// them had been app-aware for a while: a browser gets reload, back,
    /// forward, address, because the Mac says which profile the target matched.
    /// The words simply never asked the same question.
    ///
    /// The same answer, then. A phrase is text typed at whatever is listening,
    /// so what belongs here is what you would actually type there: a prompt at
    /// an agent, a URL at a browser's address bar, a command at a shell.
    ///
    /// All of them are replaceable and the editor is two taps away. These are
    /// a starting point, not a guess about you.
    private static let startersByProfile: [String: [String]] = [
        "claude": ["continue", "yes", "run the tests", "stop"],
        "codex": ["continue", "yes", "run the tests", "stop"],
        "shell": ["git status", "git diff", "make test", "clear"],
        "terminal": ["git status", "git diff", "make test", "clear"],
        // Sent after `address` selects the location bar, which is the one
        // place text into a browser reliably goes.
        "browser": ["localhost:3000", "github.com", "mail.google.com"],
        "editor": ["// TODO:", "console.log()"],
        "xcode": ["// TODO:", "print()"],
        "chat": ["on my way", "thanks", "sounds good"],
    ]

    /// For a target whose profile nobody has described, and for the generic
    /// `app` set. Deliberately empty rather than agent phrases: a window that
    /// Nimlet knows nothing about is the last place to guess what you want to
    /// say to it, and an empty section leaves the strip to its keys, which do
    /// work everywhere.
    static let genericStarters: [String] = []

    static func starters(forProfile profileID: String?) -> [String] {
        guard let profileID else { return genericStarters }
        return startersByProfile[profileID] ?? genericStarters
    }

    private static let key = "mice.quickReplies"
    @Published private var byTarget: [String: [String]]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        byTarget = data.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    /// What this target has been given, or what its profile starts with.
    ///
    /// The profile is passed in rather than looked up: the Mac owns the
    /// mapping from target to profile, and this store deliberately knows
    /// nothing about targets beyond their ids.
    func phrases(for targetID: String, profileID: String? = nil) -> [String] {
        byTarget[targetID] ?? Self.starters(forProfile: profileID)
    }

    func setPhrases(_ phrases: [String], for targetID: String) {
        let cleaned = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        byTarget[targetID] = Array(cleaned.prefix(Self.slots))
        guard let data = try? JSONEncoder().encode(byTarget) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Everything you can send to the selected target with one tap.
///
/// This was two bands with two headers and two visual languages: a row of four
/// grey keys, and below it a row of phrases. They answer the same question —
/// "say something short to this agent" — and they were separated by the one
/// thing that should have united them, which is where it goes.
///
/// The keys were the problem. Every phrase on this screen is addressed to the
/// target named above it; every key was posted at whatever had keyboard focus
/// on the Mac. For a tmux target those are not the same place and usually are
/// not even the same application — text reaches a pane without raising its
/// window, so the window is normally *not* in front. Tapping Escape to stop an
/// agent sent Escape somewhere else entirely, and it did it silently, at the
/// exact moment someone wanted something stopped.
///
/// One band now, one destination — and the destination is named by the
/// composer's own placeholder rather than by a line of small capitals above the
/// row. SEND TO CLAUDE · MAC APP was a header describing controls it sat on top
/// of; "Message Claude", written in the field you are about to type in, says
/// the same thing in the place you are already looking.
///
/// The keys offered are the ones that can actually arrive: a pane can be sent
/// Escape, Return and Control-C; copy and paste are the terminal's own
/// shortcuts and are offered only where they mean something.
struct SendBand: View {
    private struct ScrollIdentity: Hashable {
        let targetID: String?
        let profileID: String?
    }

    @ObservedObject var store: QuickReplyStore
    @Binding var fanOut: FanOut
    /// Written when the composer takes the keyboard. What it changes is the
    /// bands above and below this one, so it is reported rather than kept.
    @Binding var isComposing: Bool
    let onDictate: (NimletTarget) -> Void
    @EnvironmentObject private var client: NimletClient
    @State private var isEditing = false

    /// Spelled out because the synthesised memberwise initializer would be
    /// private — the private properties above see to that — and this band is
    /// built from another file.
    init(store: QuickReplyStore,
         fanOut: Binding<FanOut>,
         isComposing: Binding<Bool>,
         onDictate: @escaping (NimletTarget) -> Void) {
        _store = ObservedObject(wrappedValue: store)
        _fanOut = fanOut
        _isComposing = isComposing
        self.onDictate = onDictate
    }

    /// Phrases belong to one target even while several are selected: the Mac's
    /// focused target is the one whose vocabulary you are thinking in.
    private var sourceTargetID: String? {
        client.activeTargetID ?? fanOut.targetIDs.first ?? client.targets.first?.id
    }

    private var recipients: [NimletTarget] {
        guard fanOut.isActive, !fanOut.targetIDs.isEmpty else {
            return client.targets.filter { $0.id == client.activeTargetID }
        }
        return client.targets.filter { fanOut.targetIDs.contains($0.id) }
    }

    /// The buttons for what is listening.
    ///
    /// A pane running Claude Code, a pane running Codex, a bare shell and a Mac
    /// app want four different sets. Escape interrupts an agent and does
    /// nothing at a shell prompt; Control-C kills a command but quits an agent
    /// outright; \u{2318}C is the terminal's own shortcut and never reaches a pane at
    /// all. A fixed row of four keys could only ever be right for one of them.
    ///
    /// With several targets selected, only a set they all share is offered: a
    /// button that would do something different to each is worse than none.
    private var profile: ShortcutProfile? {
        guard let first = recipients.first else { return nil }
        let candidate = client.shortcuts(for: first)
        guard recipients.allSatisfy({ client.shortcuts(for: $0).id == candidate.id }) else {
            return nil
        }
        return candidate
    }

    private var actions: [ShortcutAction] {
        guard let profile else { return [] }
        return profile.actions.filter { action in
            // Dictation has left this row. It is the microphone in the
            // composer now, beside the field, because saying a sentence and
            // typing one are the same act with the same destination — where
            // Escape and Control-C are keystrokes and belong with the keys.
            guard action.kind == .key else { return false }
            // Tab and Backspace have left it too, for the same reason and in
            // the same direction: both are typing keys, and both are now on
            // either side of the composer. Leaving a copy here would be the
            // same button twice, and the row is short enough already.
            guard !ComposerBar.typingKeyIDs.contains(action.id) else { return false }
            // An action with no chord is one the agent has but this build
            // cannot name a key for; a chord no pane can receive is one the
            // terminal would eat. Neither belongs on the grid as a button that
            // does nothing when tapped.
            guard let chord = action.chord else { return false }
            return recipients.allSatisfy { $0.kind != .tmux || chord.tmuxName != nil }
        }
    }

    /// Whether this target's profile offers dictation at all.
    private var dictateAction: ShortcutAction? {
        profile?.actions.first { $0.kind == .dictate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerBar(recipients: recipients,
                        profile: profile,
                        allowsAttachments: client.status != nil,
                        client: client,
                        fanOut: $fanOut,
                        isExpanded: $isComposing,
                        canDictate: dictateAction != nil,
                        onDictate: startDictation,
                        onSend: send(text:attachments:follow:))
            // The keys and the phrases are about a message you have not begun
            // to write. With the keyboard up they are a second row of things to
            // send competing with the one in front of you.
            if !isComposing { sendRow }
        }
        .sheet(isPresented: $isEditing) {
            if let sourceTargetID {
                QuickReplyEditor(targetName: name(of: sourceTargetID),
                                 phrases: store.phrases(for: sourceTargetID,
                                                        profileID: profile?.id)) { edited in
                    store.setPhrases(edited, for: sourceTargetID)
                }
            }
        }
    }

    private func startDictation() {
        guard let target = recipients.first else { return }
        onDictate(target)
    }

    /// What the composer hands back: text, whatever images came with it, and
    /// the key that decides what becomes of them.
    private func send(text: String, attachments: [ImageAttachment], follow: ShortcutAction?) {
        guard client.requirePro() else { return }
        guard attachments.isEmpty else {
            // One upload for the whole fan-out: the bytes cross the LAN once
            // however many targets are going to be shown them. The follow-up
            // key goes with it rather than being sent from here, because here
            // is several seconds too early — the images are still going up.
            // No `submit` override: whether this presses Return is the target's
            // own setting, the same as every other send.
            client.upload(attachments,
                          caption: text,
                          to: recipients.map(\.id),
                          submit: nil,
                          follow: follow?.chord)
            return
        }
        for target in recipients {
            client.send(.text(TextPayload(text: text, targetID: target.id)))
        }
        // Typed, delivered, and then the key that decides what becomes of it.
        // Steering into a running turn or queueing behind it is the same
        // decision whether the words were typed or spoken, so it is offered
        // where the words are.
        guard let chord = follow?.chord else { return }
        client.sendKey(chord, to: recipients.map(\.id))
    }

    /// The strip: one anchored button, then everything else.
    ///
    /// This is the Touch Bar's idea — a row of controls that changes to match
    /// what is in front of you — built where that idea actually works, which
    /// is next to the picture rather than across the desk from it. Four things
    /// the Touch Bar got wrong are worth naming, because each one is a
    /// decision here:
    ///
    /// **It moved.** Every app re-laid it out, so no button was ever in the
    /// same place twice and muscle memory never formed. The fix is the anchor:
    /// the profile's leading action — `stop` for an agent, `run` for a shell,
    /// `reload` for a browser — is pinned outside the scroll view, hard
    /// against the leading gutter. Its width follows its word, but its
    /// position does not move: it is the first thing under your thumb
    /// whatever is focused, and it is what you reach for when something is
    /// running away from you. It cannot be scrolled past, and the row behind
    /// it can be shuffled freely without ever shifting it.
    ///
    /// **Everything looked the same.** A sea of identical grey pills in which
    /// Escape and a brightness slider had equal weight. Here there are three
    /// registers and they are told apart without reading: the anchor is
    /// tinted and carries its word, the keys lead with a glyph, the phrases
    /// are words in a plain capsule. The hairline marks where keystrokes end
    /// and text begins.
    ///
    /// **It did not answer back.** Glass with no travel and no haptic, so you
    /// could not tell a press from a miss without looking. Every button here
    /// dims under the finger and taps back, and the anchor taps harder than
    /// the rest — what it does is heavier.
    ///
    /// **It kept its place across contexts.** Switch apps and the strip stayed
    /// wherever it had been scrolled, showing the middle of a set you had
    /// never seen. Changing target resets this one to its beginning, so a new
    /// vocabulary is always read from the start.
    ///
    /// The one thing it does not do is reorder itself by what you press most.
    /// That is the obvious feature and it is the same mistake again: a strip
    /// that rearranges is a strip you have to read every time. Pinning the
    /// action that matters and leaving the rest alone is worth more than
    /// being clever about the order.
    private var sendRow: some View {
        HStack(spacing: 8) {
            if let anchor { anchorChip(anchor) }
            scrollingRow
        }
    }

    /// The leading action of the profile, which each set puts first for a
    /// reason it documents: the button you want without looking.
    ///
    /// Nil when several targets are selected and they do not agree on a
    /// profile — an anchor that means something different to each recipient is
    /// exactly the button this design exists to avoid.
    private var anchor: ShortcutAction? {
        guard !recipients.isEmpty else { return nil }
        return actions.first
    }

    /// Everything that is not the anchor.
    private var rest: [ShortcutAction] {
        guard anchor != nil else { return actions }
        return Array(actions.dropFirst())
    }

    private var scrollingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if actions.isEmpty && phrases.isEmpty {
                    Text(recipients.isEmpty
                         ? "Focus a target to send it something."
                         : "Those targets share no keys — pick one of them.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(minHeight: 44)
                }
                ForEach(rest) { action in
                    actionChip(action)
                }
                if !rest.isEmpty, !phrases.isEmpty {
                    // Keys and phrases look alike now, which is the point —
                    // but one is a keystroke and the other is words, and
                    // the eye should find the boundary without reading.
                    hairline.padding(.horizontal, 2)
                }
                // Indexed rather than keyed by the phrase itself: two slots
                // are allowed to hold the same words.
                ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                    chip(phrase)
                }
                editRepliesChip
            }
            .padding(.vertical, 1)
        }
        // The row runs to the edge of the glass and hands the gutter back as a
        // content margin: what is at rest lines up with the bands above it, and
        // what is past the end leaves the screen rather than being sliced off
        // inside it. The leading margin is the anchor's business now, so only
        // the trailing one is handed back here.
        .contentMargins(.trailing, Metric.gutter, for: .scrollContent)
        // Read from the start, every time.
        //
        // A scroll view keeps its offset when the view behind it is reused,
        // and this one is reused constantly: the target changes far more often
        // than the strip is rebuilt. So switching from a shell to a browser
        // left you looking at the middle of the browser's keys, with the first
        // two already off the leading edge and no sign that they existed. The
        // id makes the row a new view per profile, which is what actually
        // resets it — `defaultScrollAnchor` alone only decides where a *fresh*
        // one starts.
        .id(profile?.id ?? "none")
        .defaultScrollAnchor(.leading)
        .fadedScrollEdges()
        .padding(.trailing, -Metric.gutter)
    }

    /// The one button that does not move.
    ///
    /// Wider than the keys beside it and tinted, because it is not one of
    /// them: it is what this target is for. It keeps its word even when the
    /// profile marked it `glyphOnly` — a glyph is enough when it is one of
    /// six in a row you are scanning, and not enough when it is the button
    /// you are about to hit in a hurry without looking at it properly.
    private func anchorChip(_ action: ShortcutAction) -> some View {
        StripButton(role: .anchor, isEnabled: !recipients.isEmpty) {
            perform(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(action.label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("\(action.label), \(action.chord?.spoken ?? "key")")
        .accessibilityHint(recipients.isEmpty
                           ? "Focus a target first"
                           : "Sends to \(spokenRecipients). Always the first button on the strip.")
    }

    /// The mark this row uses for "a different kind of thing starts here".
    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    /// The pencil, and a word beside it when there is nothing to edit yet.
    ///
    /// A target whose profile nobody has written phrases for — a Mac app Nimlet
    /// knows nothing about — now gets an empty phrase section rather than four
    /// phrases meant for a coding agent. That is the right default and it
    /// leaves a hole, and a bare pencil at the end of a row of keys does not
    /// read as the way to fill it. With phrases present the glyph is enough,
    /// because by then you know what it edits.
    private var editRepliesChip: some View {
        Button { isEditing = true } label: {
            Group {
                if phrases.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                        Text("Add a phrase")
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                } else {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 44, height: 44)
                }
            }
            .background(Color.white.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(StripPress())
        .foregroundStyle(.white.opacity(0.45))
        .disabled(sourceTargetID == nil)
        .accessibilityLabel(phrases.isEmpty ? "Add a quick reply" : "Edit quick replies")
    }

    /// A key, as a capsule the same height and shape as a phrase.
    ///
    /// Keys were rounded squares in a grid while phrases were capsules in a
    /// row, which drew a line between two things that belong on the same side
    /// of it: both are one tap, both go to the target named in the composer,
    /// both answer "say something short to this agent".
    ///
    /// Most of them are now the glyph alone. The row is a scrolling one and
    /// every word in it pushes a button off the end of the screen — so the
    /// ones whose symbol is already understood (a clockwise arrow, a magnifier,
    /// a play triangle) are drawn at 44pt square with nothing written on them,
    /// and the words are kept for the buttons that cannot be guessed. Which is
    /// which is decided per set, where a profile can see its own near-twins.
    private func actionChip(_ action: ShortcutAction) -> some View {
        StripButton(role: isCommitting(action) ? .committing : .key,
                    isEnabled: !recipients.isEmpty) {
            perform(action)
        } label: {
            if action.glyphOnly {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 44, height: 44)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 12, weight: .medium))
                    Text(action.label)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
        }
        .accessibilityLabel("\(action.label), \(action.chord?.spoken ?? "key")")
        .accessibilityHint(recipients.isEmpty ? "Focus a target first"
                                              : "Sends to \(spokenRecipients)")
    }

    /// This target's words, or the ones its profile starts with.
    private var phrases: [String] {
        guard let sourceTargetID else { return [] }
        return store.phrases(for: sourceTargetID, profileID: profile?.id)
    }

    /// The one button that commits something — Return at a shell — does not
    /// look like the ones beside it that only navigate.
    private func isCommitting(_ action: ShortcutAction) -> Bool {
        guard let chord = action.chord else { return false }
        return chord.key == "enter" && !chord.control && !chord.command
    }

    /// The haptic is the button's own, chosen by register rather than fired
    /// here: what a press feels like is part of what the button is, and every
    /// one of these used to tap identically.
    private func perform(_ action: ShortcutAction) {
        guard !recipients.isEmpty, let chord = action.chord else { return }
        client.sendKey(chord, to: recipients.map(\.id))
    }

    private func chip(_ phrase: String) -> some View {
        StripButton(role: .phrase, isEnabled: !recipients.isEmpty) {
            send(phrase)
        } label: {
            Text(phrase)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
        }
        .accessibilityLabel(phrase)
        .accessibilityHint(recipients.isEmpty
                           ? "Focus a target first"
                           : "Sends to \(spokenRecipients)")
    }

    private var spokenRecipients: String {
        let names = recipients.map(\.name)
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }

    private func name(of targetID: String) -> String {
        client.targets.first { $0.id == targetID }?.name ?? "target"
    }

    private func send(_ phrase: String) {
        let ids = recipients.map(\.id)
        guard !ids.isEmpty else { return }
        // The haptic belongs to the button, which weights it by register.
        // No `submit` override: whether a phrase presses Return is the target's
        // own policy, and on a shell target that policy is the only thing
        // standing between a nudge and a command running unattended.
        client.sendText(phrase, to: ids)
    }
}

/// One button on the strip, in one of its three registers.
///
/// A `ButtonStyle` rather than a gesture, and that is not a preference: this
/// row scrolls, and a `DragGesture` or a long-press attached to a chip takes
/// the touch away from the scroll view, which stops the row scrolling wherever
/// your thumb happens to land. A style sees `isPressed` go false when the
/// finger lifts, when it slides off, *and* when the scroll view claims the
/// touch to begin a pan — the third of which is the one a gesture cannot see
/// without breaking the first two.
///
/// What it gives back is the thing the Touch Bar never had: a press you can
/// feel and see. The label dims and shrinks a little under the finger, and the
/// tap on release is weighted by what the button does — the anchor is a firm
/// click because it stops or runs something, a key is lighter, a phrase is
/// lighter still. Face down beside the keyboard, that difference is the only
/// way to tell which of them you hit.
private struct StripButton<Label: View>: View {
    enum Role {
        /// The pinned leading action. Tinted, and the heaviest tap.
        case anchor
        /// A keystroke.
        case key
        /// A keystroke that commits — Return at a shell.
        case committing
        /// Words.
        case phrase

        var fill: Color {
            switch self {
            case .anchor: return Color.accentColor.opacity(0.22)
            case .committing: return Color.accentColor.opacity(0.16)
            case .key: return Color.white.opacity(0.07)
            case .phrase: return Color.white.opacity(0.07)
            }
        }

        var foreground: Color {
            switch self {
            case .anchor, .committing: return .accentColor
            case .key: return .white.opacity(0.8)
            case .phrase: return .white.opacity(0.85)
            }
        }

        func tap() {
            switch self {
            case .anchor, .committing: Haptics.click()
            case .key: Haptics.secondaryClick()
            case .phrase: Haptics.secondaryClick()
            }
        }
    }

    let role: Role
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            guard isEnabled else { return }
            role.tap()
            action()
        } label: {
            label()
                .background(role.fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(StripPress())
        .foregroundStyle(role.foreground)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Dim and settle under the finger, and let go of the touch the moment the row
/// wants to scroll.
private struct StripPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct QuickReplyEditor: View {
    let targetName: String
    let onSave: ([String]) -> Void
    @State private var phrases: [String]
    @Environment(\.dismiss) private var dismiss

    init(targetName: String, phrases: [String], onSave: @escaping ([String]) -> Void) {
        self.targetName = targetName
        self.onSave = onSave
        var padded = phrases
        while padded.count < QuickReplyStore.slots { padded.append("") }
        _phrases = State(initialValue: Array(padded.prefix(QuickReplyStore.slots)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(phrases.indices, id: \.self) { index in
                        TextField("Phrase \(index + 1)", text: $phrases[index])
                            .autocorrectionDisabled()
                            .accessibilityLabel("Quick reply \(index + 1)")
                    }
                } header: {
                    Text("Phrases for \(targetName)")
                } footer: {
                    Text("Left blank, a slot is dropped. Each target keeps its own set.")
                }
            }
            .navigationTitle("Quick replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(phrases)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Typing, in the band it belongs to.
///
/// This was a sheet. Tapping the keyboard chip covered the screen with a modal
/// that had its own title bar, its own Cancel and Send, and its own idea of how
/// tall it should be — and it covered the one thing worth seeing while writing
/// to an agent, which is the agent. You typed at a pane you could no longer
/// look at.
///
/// So it is a band now, in the place the collapsed field already was. Tapping
/// the field grows it where it stands; the pad and the dock stand down for the
/// keyboard, the stage shrinks a little, and the pane stays on screen. Send is
/// a button in the row rather than a word in a navigation bar.
///
/// Dismissing the keyboard with nothing written puts the field back the way it
/// was; dismissing it with something written leaves the composer up, because
/// the thing you wrote still has to go somewhere. Deciding not to send it is
/// one of the places it can go, and for a while it was the one place there was
/// no way to reach: the composer would not fold away while it held a draft, and
/// the only button that emptied it was Send. So the field carries a discard at
/// its end while there is something to discard — where the microphone sits when
/// the composer is closed, because both answer "what else can happen to this
/// band" and only one of them applies at a time.
///
/// The Return switch is the same rule as everywhere else: it is a property of
/// the target, edited where the target is, and stated here rather than asked
/// about — the one irreversible part of sending a line to a shell is the Return
/// at the end.
private struct ComposerBar: View {
    let recipients: [NimletTarget]
    /// Which set of keys these targets share, so what happens *after* the text
    /// lands can be offered here rather than hunted for afterwards.
    let profile: ShortcutProfile?
    /// False when the Mac at the other end is too old to take images. The
    /// buttons are absent rather than disabled: there is nothing to tap towards.
    let allowsAttachments: Bool
    /// Handed over rather than read from the environment: this view only ever
    /// calls methods on it, and a missing `@EnvironmentObject` is a crash at the
    /// moment somebody taps the field.
    let client: NimletClient
    @Binding var fanOut: FanOut
    @Binding var isExpanded: Bool
    /// Whether this target's profile offers dictation at all.
    let canDictate: Bool
    let onDictate: () -> Void
    let onSend: (String, [ImageAttachment], ShortcutAction?) -> Void

    @State private var text = ""
    @State private var followID: String?
    @State private var attachments: [ImageAttachment] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var isPreparing = false
    @State private var isCameraOpen = false
    @State private var still: Still?
    @State private var problem: String?
    @FocusState private var focused: Bool
    /// Off until it is asked for. Sending one message to four agents at once is
    /// a real thing to want and a rare one, and it was holding the best seat on
    /// the screen — first in the row, beside the field, on every single send.
    @AppStorage("mice.fanOut.shown") private var showsFanOut = false

    /// The keys that belong beside a text field rather than in the row of
    /// commands under it. Kept here so the send row can leave them out: one
    /// button, one place.
    static let typingKeyIDs: Set<String> = ["tab", "delete"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The field is first in this row in both states: whatever appears
            // below it must not be able to move it out from under the keyboard
            // it just raised.
            //
            // Tab on one side of it, Backspace on the other — the two keys you
            // press *while writing* rather than instead of writing, and the two
            // that were furthest away, buried in a row that scrolls several
            // taps from the thing they act on. Completing a path at a prompt is
            // one thumb at the left edge now.
            //
            // Both stand down while this composer is open. The keyboard is up
            // then, and a Backspace that deletes on the Mac sitting an inch
            // from one that deletes what you are typing is a trap.
            HStack(alignment: .bottom, spacing: 8) {
                if showsFanOut { fanOutChip }
                if !isExpanded, let tab = typingKey("tab") { keyButton(tab) }
                field
                if !isExpanded, let delete = typingKey("delete") { keyButton(delete) }
            }

            if isExpanded {
                if !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments) { attachment in
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
                // A row of its own only when there is a choice to make or
                // something went wrong. What Return will do is a mark in the
                // row below, not a line of prose here.
                if !followUps.isEmpty || problem != nil { noteRow }
                actionRow
            }
        }
        .padding(isExpanded ? 8 : 0)
        .background(card)
        .onChange(of: focused) { _, now in
            // Losing the keyboard with something still written keeps the
            // composer open: the send button is the only way that text leaves,
            // and folding it away would take the button with it.
            withAnimation(.spring(duration: 0.3)) {
                isExpanded = now || hasSomethingToSend
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            absorb(items)
        }
        .fullScreenCover(item: $still) { still in
            AnnotationSheet(still: still.image, title: still.title) { annotated in
                append([annotated])
            }
        }
        .fullScreenCover(isPresented: $isCameraOpen) {
            CameraPicker { image in
                // A photograph, so JPEG: it is a lens on a desk, not a
                // screenshot of text.
                guard let attachment = ImagePreparation.prepare(image, lossless: false) else {
                    problem = "That photo couldn't be prepared"
                    return
                }
                append([attachment])
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var card: some View {
        if isExpanded {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                )
        }
    }

    // MARK: - The field

    /// One text field in both states, growing on its own axis rather than being
    /// swapped for a taller one: swapping would take the keyboard with it.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                // Both ends grow. A resting bar pinned to one line cut a
                // pasted paragraph down to its first few words with no way to
                // see the rest without opening the keyboard again.
                .lineLimit(isExpanded ? 1...9 : 1...3)
                .focused($focused)
                .tint(Color.accentColor)
                .foregroundStyle(.white)
                .padding(.leading, 15)
                .padding(.trailing, showsInlineMic || showsDiscard ? 0 : 15)
                .padding(.vertical, isExpanded ? 7 : 0)
                .frame(minHeight: 44)
                .disabled(recipients.isEmpty)
            if showsInlineMic {
                micButton
            } else if showsDiscard {
                discardButton
            }
        }
        // The fill is a control, not decoration. A text field only claims the
        // box its own glyphs sit in, so a tap on the capsule's padding — which
        // is most of an empty one — landed on nothing at all.
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 16 : 22, style: .continuous)
                .fill(Color.white.opacity(isExpanded ? 0.06 : 0.07))
                .contentShape(RoundedRectangle(cornerRadius: isExpanded ? 16 : 22, style: .continuous))
                .onTapGesture { if !recipients.isEmpty { focused = true } }
        )
    }

    /// One of the two keys flanking the field, if this target has it.
    ///
    /// Read out of the target's own set rather than sent as a bare chord: a
    /// pane that cannot receive Tab must not be offered it, and a profile that
    /// spends Tab on something else — Codex, where it queues a message — has
    /// no `tab` action, so no tab key appears. A key that does something other
    /// than what is drawn on it is worse than no key.
    private func typingKey(_ id: String) -> ShortcutAction? {
        guard let action = profile?.actions.first(where: { $0.id == id }),
              let chord = action.chord,
              recipients.allSatisfy({ $0.kind != .tmux || chord.tmuxName != nil }) else { return nil }
        return action
    }

    private func keyButton(_ action: ShortcutAction) -> some View {
        Button {
            guard let chord = action.chord, !recipients.isEmpty else { return }
            Haptics.click()
            client.sendKey(chord, to: recipients.map(\.id))
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .disabled(recipients.isEmpty)
        .opacity(recipients.isEmpty ? 0.4 : 1)
        .accessibilityLabel("\(action.label), \(action.chord?.spoken ?? "key")")
        .accessibilityHint(recipients.isEmpty ? "Focus a target first"
                                              : "Sends to \(spokenRecipients)")
    }

    /// The microphone lives in the collapsed field and nowhere else. Offered
    /// while the composer is open it would be a button that throws away what is
    /// in front of it: the dictation console takes this band while it runs.
    private var showsInlineMic: Bool { canDictate && !isExpanded }

    /// And the discard lives in the open one, for the same reason in reverse:
    /// there is nothing to throw away until something has been written.
    private var showsDiscard: Bool { isExpanded && hasSomethingToSend }

    /// Empties the composer and puts the band back the way it was — the text,
    /// the images and the follow-up key, since they were one message.
    ///
    /// No confirmation, and none anywhere else this app throws something away
    /// either: a recording slid off a tile goes without asking, and so does a
    /// transcript discarded from the review sheet. The haptic is the failure
    /// one on purpose — the same short buzz those two give, which is what "that
    /// is gone" already feels like here.
    private var discardButton: some View {
        Button {
            Haptics.failure()
            reset()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.35))
        .accessibilityLabel("Discard this message")
        .accessibilityHint("Empties the composer, including anything attached")
    }

    private var micButton: some View {
        Button {
            focused = false
            onDictate()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
        .disabled(recipients.isEmpty)
        .accessibilityLabel("Dictate")
        .accessibilityHint(recipients.isEmpty ? "Focus a target first"
                                              : "Sends to \(spokenRecipients)")
    }

    private var fanOutChip: some View {
        Button {
            guard fanOut.isActive || client.requirePro() else { return }
            fanOut.isActive.toggle()
            if !fanOut.isActive { fanOut.targetIDs.removeAll() }
            Haptics.secondaryClick()
        } label: {
            Image(systemName: fanOut.isActive ? "person.2.fill" : "person.2")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
                .background(fanOut.isActive ? Color.accentColor.opacity(0.22)
                                            : Color.white.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(fanOut.isActive ? Color.accentColor : .white.opacity(0.8))
        .accessibilityLabel("Send to several targets")
        .accessibilityValue(fanOut.isActive ? "on" : "off")
        .accessibilityHint("Turns the dock into a selection list")
    }

    // MARK: - What happens when it lands

    private var noteRow: some View {
        HStack(spacing: 10) {
            if !followUps.isEmpty { followMenu }
            if let note = spokenNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(noteColor)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What is left worth writing out: a failure, or what the chosen follow-up
    /// key is going to do. Everything else this row used to say is now said by
    /// the mark beside the send button.
    private var spokenNote: String? {
        if let problem { return problem }
        if let follow { return follow.note }
        return nil
    }

    /// A message typed while a turn is running either redirects it or waits
    /// behind it, and that is decided by a key pressed after the text lands.
    /// Deciding it here means one action instead of type, send, then find the
    /// button.
    ///
    /// A segmented control with three stops and a caption under it, which is
    /// what this was, is two rows for a choice almost nobody changes.
    private var followMenu: some View {
        Menu {
            Button("Just place it") { followID = nil }
            ForEach(followUps) { action in
                Button(action.label.capitalized) { followID = action.id }
            }
        } label: {
            HStack(spacing: 5) {
                Text(follow?.label.capitalized ?? "Just place it")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(Color.white.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .foregroundStyle(follow == nil ? Color.white.opacity(0.7) : Color.accentColor)
        .accessibilityLabel("What happens after this lands")
        .accessibilityValue(follow?.label ?? "just place it")
    }

    /// Only keys that act on what was just typed. Offering the whole set here
    /// would be a second copy of the send row inside a composer about one
    /// message.
    private var followUps: [ShortcutAction] {
        guard let profile else { return [] }
        return profile.actions.filter { ["steer", "queue"].contains($0.id) && $0.chord != nil }
    }

    private var follow: ShortcutAction? {
        followUps.first { $0.id == followID }
    }

    private var noteColor: Color {
        problem == nil ? .white.opacity(0.45) : .orange
    }

    /// Return, as a mark rather than a sentence.
    ///
    /// "Claude presses Return when this lands." was a line of prose set across
    /// the whole composer, under everything else, restating on every single
    /// message a setting that belongs to the target and changes about once a
    /// month. It is one glyph beside the send button now — lit when Return is
    /// coming, dim when the text will sit in the prompt and wait — and the
    /// sentence survives where it is worth a sentence: read out by VoiceOver,
    /// and written in full in the target's own settings.
    ///
    /// Nothing is drawn for a fan-out. Each target answers this for itself, and
    /// one mark cannot speak for four of them.
    @ViewBuilder private var returnMark: some View {
        if recipients.count == 1, let only = recipients.first {
            let presses = only.allowAutoSubmit && only.submitOnSend
            Image(systemName: "return")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(presses ? Color.accentColor : .white.opacity(0.25))
                .frame(width: 30, height: 44)
                .accessibilityLabel(returnNote)
        }
    }

    /// What Return will do, read from the targets rather than asked about.
    ///
    /// Each target carries its own answer, so a fan-out to several of them has
    /// no single one to state — and inventing one here would be a claim about
    /// targets this composer is not in a position to make.
    private var returnNote: String {
        guard let only = recipients.first else { return "" }
        guard recipients.count == 1 else {
            return "Each target follows its own Return setting."
        }
        guard only.allowAutoSubmit else { return "\(only.name) never presses Return." }
        return only.submitOnSend
            ? "\(only.name) presses Return when this lands."
            : "\(only.name) leaves it in the prompt for you."
    }

    // MARK: - Images, and sending

    private var actionRow: some View {
        HStack(spacing: 4) {
            if allowsAttachments {
                // Where images come from: the library for a screenshot
                // AirDropped or taken on this phone, the camera for whatever is
                // in front of it, and the Mac's own screen for the thing being
                // pointed at.
                PhotosPicker(selection: $picked,
                             maxSelectionCount: UploadChannel.maxAttachments,
                             matching: .images,
                             photoLibrary: .shared()) {
                    glyph("photo.on.rectangle")
                }
                .disabled(isFull)
                .opacity(isFull ? 0.4 : 1)
                .accessibilityLabel("Attach a photo")

                if CameraPicker.isAvailable {
                    Button { isCameraOpen = true } label: { glyph("camera") }
                        .buttonStyle(.plain)
                        .disabled(isFull)
                        .opacity(isFull ? 0.4 : 1)
                        .accessibilityLabel("Take a photo")
                }

                // The one this app is actually for: what is on the Mac's screen
                // right now. Circling the thing you are asking about is one
                // gesture where describing where it is on screen is a paragraph.
                if let target = recipients.first {
                    Button { annotate(target) } label: { glyph("pencil.tip.crop.circle") }
                        .buttonStyle(.plain)
                        .disabled(isFull || isPreparing)
                        .opacity(isFull || isPreparing ? 0.4 : 1)
                        .accessibilityLabel("Draw on your Mac's screen and attach it")
                }
            }
            if isPreparing {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }
            Spacer(minLength: 0)
            returnMark
            sendButton
        }
        .foregroundStyle(.white.opacity(0.75))
    }

    /// The house capsule, icon only. These carried the words Photos, Camera and
    /// Screen under a field that already says what the composer is for, in a
    /// row that has to hold a send button as well.
    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var sendButton: some View {
        Button {
            Haptics.click()
            if hasSomethingToSend {
                // Refused Pro sends keep their draft; empty input can always close.
                guard client.requirePro() else { return }
                onSend(text, attachments, follow)
                reset()
            } else {
                collapse()
            }
        } label: {
            Image(systemName: hasSomethingToSend ? "arrow.up" : "keyboard.chevron.compact.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(hasSomethingToSend ? Color.accentColor : Color.white.opacity(0.09),
                            in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasSomethingToSend ? .white : .white.opacity(0.75))
        .disabled(isPreparing || (hasSomethingToSend && recipients.isEmpty))
        .accessibilityLabel(hasSomethingToSend ? "Send" : "Dismiss keyboard")
        .accessibilityHint(hasSomethingToSend
                          ? (recipients.isEmpty ? "Focus a target first" : "Sends to \(spokenRecipients)")
                          : "Closes the empty composer")
    }

    private var placeholder: String {
        guard let only = recipients.first else { return "Focus a target to send it something" }
        return recipients.count == 1 ? "Message \(only.name)"
                                     : "Message \(recipients.count) targets"
    }

    private var spokenRecipients: String {
        let names = recipients.map(\.name)
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }

    private var hasSomethingToSend: Bool {
        !attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isFull: Bool { attachments.count >= UploadChannel.maxAttachments }

    private func reset() {
        text = ""
        attachments = []
        followID = nil
        problem = nil
        collapse()
    }

    private func collapse() {
        focused = false
        // Mirroring's hardware keyboard can leave UIKit's field focused
        // after SwiftUI clears FocusState. End the editing session as well.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        withAnimation(.spring(duration: 0.3)) { isExpanded = false }
    }

    /// Decodes and resizes what the picker returned, then clears the selection
    /// so picking the same photograph twice in a row is possible.
    private func absorb(_ items: [PhotosPickerItem]) {
        isPreparing = true
        problem = nil
        Task {
            let result = await AttachmentLoader.load(items)
            append(result.attachments)
            if let trouble = result.problem { problem = trouble }
            picked = []
            isPreparing = false
        }
    }

    /// Asks the Mac for a screenshot, then opens it to be drawn on.
    private func annotate(_ target: NimletTarget) {
        isPreparing = true
        problem = nil
        client.fetchStill(for: target.id) { result in
            isPreparing = false
            switch result {
            case .success(let fetched):
                still = fetched
            case .failure(let refusal):
                problem = refusal.message
            }
        }
    }

    private func append(_ new: [ImageAttachment]) {
        let room = UploadChannel.maxAttachments - attachments.count
        guard room > 0 else {
            problem = "\(UploadChannel.maxAttachments) images is the limit for one message"
            return
        }
        attachments.append(contentsOf: new.prefix(room))
        if new.count > room {
            problem = "\(UploadChannel.maxAttachments) images is the limit for one message"
        }
    }
}
