import Foundation
import Network

/// A fixed-port listener must come back after wake or a network change even
/// when the previous socket has not finished releasing its port yet.
/// All methods and callbacks run on the supplied serial queue.
final class RecoveringListener {
    private let queue: DispatchQueue
    private let makeListener: () throws -> NWListener
    private var listener: NWListener?
    private var retry: DispatchWorkItem?
    private var generation = 0
    private var stopped = false
    private var failures = 0

    private(set) var state: NWListener.State = .setup
    var stateUpdateHandler: ((NWListener.State) -> Void)?
    var newConnectionHandler: ((NWConnection) -> Void)?
    var newConnectionLimit = NWListener.InfiniteConnectionLimit {
        didSet { listener?.newConnectionLimit = newConnectionLimit }
    }

    init(queue: DispatchQueue, makeListener: @escaping () throws -> NWListener) {
        self.queue = queue
        self.makeListener = makeListener
    }

    /// Queue the first bind so callers can register ownership before callbacks.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.bind()
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        generation &+= 1
        retry?.cancel()
        retry = nil
        listener?.cancel()
        listener = nil
        publish(.cancelled)
    }

    private func bind() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        generation &+= 1
        let attempt = generation
        do {
            let next = try makeListener()
            listener = next
            next.newConnectionLimit = newConnectionLimit
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self, let next, !self.stopped,
                      self.generation == attempt, self.listener === next else { return }
                self.publish(state)
                switch state {
                case .ready: self.failures = 0
                case .failed:
                    next.cancel()
                    self.listener = nil
                    self.scheduleRetry()
                default: break
                }
            }
            next.newConnectionHandler = { [weak self, weak next] connection in
                guard let self, let next, !self.stopped,
                      self.generation == attempt, self.listener === next else {
                    connection.cancel()
                    return
                }
                self.newConnectionHandler?(connection)
            }
            next.start(queue: queue)
        } catch {
            publish(.failed((error as? NWError) ?? .posix(.EIO)))
            scheduleRetry()
        }
    }

    private func publish(_ state: NWListener.State) {
        self.state = state
        stateUpdateHandler?(state)
    }

    private func scheduleRetry() {
        guard !stopped, retry == nil else { return }
        let delay = min(0.25 * pow(2, Double(min(failures, 5))), 5)
        failures += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retry = nil
            self.bind()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
