import Foundation
import Combine

/// The Mac's side of an agent asking permission.
///
/// Holds the pending set, runs the clock that expires it, and tells whoever is
/// listening. The rules themselves live in `ApprovalLedger`, which has no
/// timers and no network in it and can therefore be tested; this adds exactly
/// the three things that cannot be: a main-thread home for the published list,
/// a sweep scheduled at the next deadline, and the callbacks the server wires
/// to its sockets.
@MainActor
final class ApprovalBroker: ObservableObject {
    static let shared = ApprovalBroker()

    /// What the menu bar draws, and what a phone is sent when it asks to catch
    /// up after a reconnect.
    @Published private(set) var pending: [ApprovalRequest] = []

    /// A new request the phones should be shown.
    var onAdded: ((ApprovalRequest) -> Void)?
    /// A request that is over, however it ended. Always fires exactly once per
    /// request that was ever added.
    var onResolved: ((ApprovalResolution) -> Void)?

    private var ledger = ApprovalLedger()
    private var sweep: DispatchWorkItem?

    private init() {}

    @discardableResult
    func submit(_ request: ApprovalRequest) -> ApprovalLedger.AddOutcome {
        let outcome = ledger.add(request)
        switch outcome {
        case .added:
            publish()
            onAdded?(request)
            miceLog.info("approval asked: \(request.targetName, privacy: .public) — \(request.title, privacy: .public)")
        case .duplicate:
            break
        case .refused(let resolution):
            miceLog.error("approval refused: \(resolution.note ?? "", privacy: .public)")
            onResolved?(resolution)
        }
        return outcome
    }

    func decide(id: String, decision: ApprovalDecision, reason: String? = nil, by deviceName: String?) {
        decide(id: id, with: ApprovalAnswer(decision: decision, reason: reason), by: deviceName)
    }

    func decide(id: String, with answer: ApprovalAnswer, by deviceName: String?) {
        guard let resolution = ledger.resolve(id: id, with: answer, by: deviceName) else {
            // Already gone: expired, or answered on another phone a moment ago.
            // The asker has been told once; telling it twice is worse.
            miceLog.info("approval \(id, privacy: .public): decision arrived for nothing pending")
            return
        }
        publish()
        miceLog.info("approval \(resolution.decision.rawValue, privacy: .public) (\(resolution.reason.rawValue, privacy: .public)) by \(deviceName ?? "the Mac", privacy: .public)")
        onResolved?(resolution)
    }

    /// The process that asked went away, so nobody is left to answer to.
    func withdraw(ids: Set<String>) {
        let gone = ledger.withdraw(ids: ids)
        guard !gone.isEmpty else { return }
        publish()
        gone.forEach { onResolved?($0) }
    }

    /// The Mac restarted its listeners and took these askers' connections
    /// with it. They are still waiting and will dial back in; the cards stay
    /// up for `ApprovalLedger.reconnectGrace` while they do.
    func orphan(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        ledger.orphan(ids: ids)
        miceLog.info("approval: \(ids.count, privacy: .public) asker(s) cut off by a restart; waiting for them to come back")
        scheduleSweep()
    }

    func has(id: String) -> Bool { ledger.request(id: id) != nil }

    private func publish() {
        pending = ledger.pending
        scheduleSweep()
    }

    /// One timer, armed for the nearest deadline rather than ticking. The list
    /// is at most eight long and usually empty; a second-by-second wakeup would
    /// exist only to find nothing.
    private func scheduleSweep() {
        sweep?.cancel()
        sweep = nil
        guard let next = ledger.nextExpiry() else { return }
        // 50ms past the deadline, so the sweep never runs a hair early and
        // finds the request not yet expired — which would leave it pending with
        // no timer armed for it.
        let delay = max(0.05, Double(next - ApprovalClock.now()) / 1000 + 0.05)
        let item = DispatchWorkItem { [weak self] in self?.runSweep() }
        sweep = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runSweep() {
        let expired = ledger.expire()
        let lost = ledger.sweepOrphans()
        publish()
        for resolution in expired {
            miceLog.info("approval expired: \(resolution.requestID, privacy: .public) → \(resolution.decision.rawValue, privacy: .public)")
            onResolved?(resolution)
        }
        for resolution in lost {
            miceLog.info("approval withdrawn: \(resolution.requestID, privacy: .public); its asker never came back")
            onResolved?(resolution)
        }
    }
}
