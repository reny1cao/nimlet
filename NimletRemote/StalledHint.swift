import SwiftUI

/// What to do when a spinner has stopped being a moment and started being a
/// problem.
///
/// Every "asking the Mac…" in this app used to spin for ever, because the
/// request has no timeout and the answer usually arrives in under a second.
/// Usually. This shows nothing for `after` seconds and then a sentence with
/// the likely cause — and, if given one, a button that does the obvious thing.
struct StalledHint: View {
    let after: TimeInterval
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @State private var stalled = false

    var body: some View {
        Group {
            if stalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .font(.caption.weight(.medium))
                    }
                }
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            withAnimation { stalled = true }
        }
    }
}
