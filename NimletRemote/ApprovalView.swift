import SwiftUI

/// What a blocked agent looks like from the phone.
///
/// Two surfaces, because the decision has two moments. The banner is the one
/// you see without looking for it — it sits above the targets and says which
/// agent is waiting and for how much longer. The sheet is where you read what
/// it actually wants and answer it.
///
/// A permission prompt and a question are one card. Both stop the agent until
/// somebody picks, and the only difference is what there is to pick: Approve
/// or Deny, or the choices the agent offered. Same banner, same sheet, same
/// path back to the session that asked.
///
/// Neither surface ever decides for you. Nothing here approves on a timer, on
/// a swipe, or by being dismissed; the only thing that happens by itself is
/// what the Mac does when the wait runs out — deny, or leave it to the agent's
/// own prompt on the Mac — and neither is a yes.

// MARK: - Banner

struct ApprovalBanner: View {
    let requests: [ApprovalRequest]
    let onOpen: () -> Void

    var body: some View {
        guard let first = requests.first else { return AnyView(EmptyView()) }
        return AnyView(
            Button(action: onOpen) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = ApprovalClock.millis(at: context.date)
                    HStack(spacing: 10) {
                        Image(systemName: first.isQuestion ? "questionmark.bubble.fill" : "hand.raised.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline(first))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(first.detail.firstLine)
                                .font(.system(size: 11, design: first.isQuestion ? .default : .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Text(ApprovalWait.clock(first.secondsRemaining(at: now)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1)
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel(first))
            .accessibilityHint(first.isQuestion ? "Opens the question so you can answer it"
                                                : "Opens the request so you can approve or deny it")
            .accessibilityAddTraits(.isButton)
        )
    }

    private func headline(_ request: ApprovalRequest) -> String {
        let what = request.isQuestion ? "\(request.targetName) has a question" : "\(request.targetName) is waiting for you"
        return requests.count > 1 ? "\(what) · \(requests.count) waiting" : what
    }

    private func spokenLabel(_ request: ApprovalRequest) -> String {
        let remaining = request.secondsRemaining(at: ApprovalClock.now())
        let others = requests.count > 1 ? ", \(requests.count - 1) more waiting" : ""
        let what = request.isQuestion ? "has a question: \(request.detail.firstLine)" : "is waiting for a decision: \(request.title)"
        return "\(request.targetName) \(what). \(request.expiryPhrase) in \(remaining) seconds\(others)"
    }
}

// MARK: - Sheet

struct ApprovalSheet: View {
    let requests: [ApprovalRequest]
    /// The one a notification tap was about, when it was opened by one.
    ///
    /// The list is ordered by deadline and the sheet shows one card at a time,
    /// which is the right rule for the sheet being opened by hand. It is the
    /// wrong rule for a banner: you read *that* request, you tapped Approve on
    /// *that* request, and being handed a different one with the buttons in
    /// the same place is how somebody approves the wrong command. The deadline
    /// order takes over again as soon as this one is answered.
    var focusID: String?
    /// Still on the way to the Mac — a notification tap that launched the app.
    /// What is waiting is not known yet, which is not the same as nothing.
    var isReaching = false
    let decide: (ApprovalRequest, ApprovalAnswer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reasoning = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    /// Per question, by index: the labels picked, and anything typed instead.
    @State private var picked: [Int: [String]] = [:]
    @State private var typed: [Int: String] = [:]
    @FocusState private var typing: Int?

    /// Offered because the alternative is an empty field and a finger: the
    /// point of a reason is that the agent stops asking, and three words it can
    /// act on beat a paragraph nobody types one-handed.
    private static let readyReasons = ["Too risky", "Wrong directory", "Use the existing helper"]
    private static let readyDeclines = ["Skip it for now", "Use your judgement", "I\u{2019}ll decide at the Mac"]

    /// The card on screen: the one that was tapped if it is still pending, and
    /// otherwise the one with the least time left.
    private var current: ApprovalRequest? {
        if let focusID, let asked = requests.first(where: { $0.id == focusID }) { return asked }
        return requests.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let request = current {
                    if reasoning {
                        reasonPane(for: request)
                    } else if request.isQuestion {
                        questionPane(for: request)
                    } else {
                        requestPane(for: request)
                    }
                } else if isReaching {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reaching your Mac…")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The last card was answered, expired or withdrawn while
                    // this was open. Saying so beats a sheet that vanishes.
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Nothing is waiting")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Not an answer. The request stays pending and the banner
                    // stays up; only the Mac's clock can end it without you.
                    Button("Not now") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: current?.id) { _, _ in
            reasoning = false
            reason = ""
            picked = [:]
            typed = [:]
        }
    }

    // MARK: Permission

    /// What is being decided scrolls; the buttons do not. A long command, a
    /// "don't ask again" rule and large text together are taller than a small
    /// phone, and the one part that must never be pushed off the screen is the
    /// part that answers.
    private func requestPane(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(request)

                    Text(request.title.hasSuffix("?") ? request.title : "\(request.title)?")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    detail(request)
                    footnotes(request)
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 10) {
                Button {
                    Haptics.click()
                    decide(request, .deny)
                } label: {
                    Text("Deny").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    Haptics.success()
                    decide(request, .approve)
                } label: {
                    Text("Approve").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.body.weight(.semibold))
            .controlSize(.large)

            if let rule = request.alwaysAllowRule {
                // The agent's own second option, worded as it applies: the
                // rule is added on the Mac exactly as if it were picked there.
                Button {
                    Haptics.success()
                    decide(request, ApprovalAnswer(decision: .approve, alwaysAllow: true))
                } label: {
                    Text("Approve, and don\u{2019}t ask again for \(rule)")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Button("Deny with a reason…") {
                reasoning = true
                reasonFocused = true
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(16)
    }

    /// Sized to what is actually being decided: a one-line command is one
    /// line, and a fifty-line diff scrolls with the rest of the card.
    private func detail(_ request: ApprovalRequest) -> some View {
        Text(request.detail)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("What is being asked")
            .accessibilityValue(request.detail)
    }

    // MARK: Question

    private func questionPane(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(request)
                    ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                        questionBlock(question, index: index)
                    }
                    footnotes(request)
                }
                .padding(.vertical, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)

            Button {
                Haptics.success()
                decide(request, ApprovalAnswer(decision: .approve, answers: answers(for: request)))
            } label: {
                Text(request.questions.count > 1 ? "Send answers" : "Send answer")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .font(.body.weight(.semibold))
            .controlSize(.large)
            .disabled(answers(for: request) == nil)

            Button("Decline to answer…") {
                reasoning = true
                reasonFocused = true
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(16)
    }

    private func questionBlock(_ question: ApprovalQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.yellow.opacity(0.85))
            }
            Text(question.question)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if question.allowsMultiple {
                Text("Pick any that apply")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(question.options, id: \.self) { option in
                optionRow(option, question: question, index: index)
            }
            TextField(question.options.isEmpty ? "Your answer" : "Or type your own answer",
                      text: Binding(get: { typed[index] ?? "" },
                                    set: { typed[index] = $0 }),
                      axis: .vertical)
                .lineLimit(1...4)
                .focused($typing, equals: index)
                .font(.body)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Your own answer to \(question.question)")
        }
    }

    private func optionRow(_ option: ApprovalOption, question: ApprovalQuestion, index: Int) -> some View {
        let isPicked = picked[index]?.contains(option.label) ?? false
        let isOverridden = !(typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            Haptics.secondaryClick()
            var labels = picked[index] ?? []
            if question.allowsMultiple {
                if isPicked { labels.removeAll { $0 == option.label } } else { labels.append(option.label) }
            } else {
                labels = isPicked ? [] : [option.label]
            }
            picked[index] = labels
            // A pick is an answer: whatever was typed instead would win over it.
            typed[index] = nil
            typing = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.allowsMultiple
                      ? (isPicked ? "checkmark.square.fill" : "square")
                      : (isPicked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 18))
                    .foregroundStyle(isPicked ? Color.accentColor : .white.opacity(0.45))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(minHeight: 44)
            .background(Color.white.opacity(isPicked ? 0.14 : 0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isOverridden ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.detail.map { "\(option.label), \($0)" } ?? option.label)
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }

    /// One answer per question, or nil while any is still unanswered.
    private func answers(for request: ApprovalRequest) -> [String]? {
        var result: [String] = []
        for index in request.questions.indices {
            guard let answer = ApprovalQuestion.answer(picking: picked[index] ?? [], typed: typed[index]) else {
                return nil
            }
            result.append(answer)
        }
        return result
    }

    // MARK: Saying no

    private func reasonPane(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(request)

            Text(request.isQuestion ? "Tell \(request.targetName) what to do instead" : "Tell \(request.targetName) why")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(request.isQuestion
                 ? "Without a word it will likely ask the same question again."
                 : "Without a reason it will likely ask for the same thing again.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))

            Text(request.detail.firstLine)
                .font(.system(size: 13, design: request.isQuestion ? .default : .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            TextField(request.isQuestion ? "What to do instead" : "Why not", text: $reason, axis: .vertical)
                .lineLimit(1...4)
                .focused($reasonFocused)
                .font(.body)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(request.isQuestion ? "What to do instead" : "Reason for denying")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(request.isQuestion ? Self.readyDeclines : Self.readyReasons, id: \.self) { phrase in
                        Button {
                            reason = phrase
                            Haptics.secondaryClick()
                        } label: {
                            Text(phrase)
                                .font(.footnote)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                Haptics.click()
                decide(request, ApprovalAnswer(decision: .deny, reason: reason))
            } label: {
                Text(sendLabel(request))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .font(.body.weight(.semibold))
            .controlSize(.large)

            Button(request.isQuestion ? "Back to the question" : "Back to the request") { reasoning = false }
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(16)
    }

    private func sendLabel(_ request: ApprovalRequest) -> String {
        let empty = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if request.isQuestion { return empty ? "Decline" : "Send and decline" }
        return empty ? "Deny" : "Send and deny"
    }

    // MARK: Shared

    @ViewBuilder private func footnotes(_ request: ApprovalRequest) -> some View {
        if requests.count > 1 {
            Text("\(requests.count - 1) more waiting behind this one.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        Text(request.returnsToMac
             ? "Nimlet never answers for you. Unanswered, this waits for you on the Mac, in \(request.targetName)\u{2019}s own prompt."
             : "Nimlet never approves for you. Unanswered, this denies itself.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ request: ApprovalRequest) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = ApprovalClock.millis(at: context.date)
            let remaining = request.secondsRemaining(at: now)
            HStack(spacing: 8) {
                Image(systemName: request.isQuestion ? "questionmark.bubble" : request.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.yellow)
                Text(request.targetName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(request.expiryPhraseMidSentence) in \(ApprovalWait.clock(remaining))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining <= 15 ? .orange : .white.opacity(0.5))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(request.targetName), \(request.expiryPhraseMidSentence) in \(remaining) seconds")
        }
    }
}

// MARK: - Shared bits

extension ApprovalRequest {
    /// What happens at the end of the wait, as the start of a sentence.
    var expiryPhrase: String {
        returnsToMac ? "Back to your Mac" : (onExpiry == .approve ? "Approves itself" : "Denies itself")
    }

    /// The same, after a comma: "back to your Mac", keeping the capital M.
    var expiryPhraseMidSentence: String {
        expiryPhrase.prefix(1).lowercased() + expiryPhrase.dropFirst()
    }
}

private extension String {
    /// The first line, with a note when there were more — so a two-line command
    /// is never shown as if it were the whole of what is being approved.
    var firstLine: String {
        let lines = split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return self }
        guard lines.count > 1 else { return String(first) }
        return "\(first) · \(lines.count - 1) more line\(lines.count == 2 ? "" : "s")"
    }
}

extension ApprovalRequest.Kind {
    var symbol: String {
        switch self {
        case .command: return "terminal"
        case .edit: return "square.and.pencil"
        case .network: return "globe"
        case .other: return "questionmark.circle"
        }
    }
}
