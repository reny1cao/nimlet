import Foundation

/// Retry timing for a link that should come back on its own.
///
/// Both sockets to the Mac grew one of these independently, with different
/// ladders — 500ms to 8s on the control channel, 400ms to 5s on the panel — for
/// no reason anyone chose. Two ladders for one Wi-Fi link means reconnect
/// behaviour nobody can predict, and a fix to one (jitter, a cancellation race)
/// never reaching the other.
@MainActor
final class Backoff {
    private let first: Duration
    private let ceiling: Duration
    private var next: Duration
    private var task: Task<Void, Never>?

    init(first: Duration = .milliseconds(500), ceiling: Duration = .seconds(8)) {
        self.first = first
        self.ceiling = ceiling
        self.next = first
    }

    /// True while a retry is already pending, so callers do not stack them.
    var isWaiting: Bool { task != nil }

    /// Back to the short delay: the link is up, so the next failure is a fresh one.
    func reset() {
        next = first
        cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Runs `work` after the current delay, then doubles it.
    func schedule(_ work: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        // ±20%, so the panel and the listen socket — which lose their link at
        // the same instant as the control one — do not all redial the Mac in
        // the same millisecond, every time, against its connection cap.
        let delay = next * Double.random(in: 0.8...1.2)
        next = min(next * 2, ceiling)
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.task = nil
            work()
        }
    }
}
