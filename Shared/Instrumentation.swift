import Foundation
import OSLog

/// Percentile timing for the pointer hot path, shared by both ends.
///
/// Enable on the Mac with:
///   defaults write com.renyicao.mice.host mice.instrument -bool YES
///
/// Off by default: sampling every move at 120 Hz is itself measurable, so this
/// must not be something either app does when nobody is looking at it.
public final class Instrumentation {
    public static let shared = Instrumentation()

    /// Each app points this at its own logger at launch.
    public static var logger = Logger(subsystem: "com.renyicao.mice", category: "perf")
    public static var isEnabled = UserDefaults.standard.bool(forKey: "mice.instrument")

    private let lock = NSLock()
    private var series: [String: [UInt64]] = [:]
    private var lastMoveArrival: UInt64 = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private let windowNanos: UInt64 = 1_000_000_000
    private let maxSamples = 8192

    private init() {}

    public static func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mice.instrument")
    }

    @inline(__always)
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    @inline(__always)
    public func record(_ key: String, since start: UInt64) {
        guard Self.isEnabled else { return }
        add(key, Self.now() &- start)
        // The reporting window has to be driven from here too: the phone never
        // calls recordMoveArrival, so it would otherwise never report.
        flushIfWindowElapsed()
    }

    /// A size rather than a duration, reported in the same percentile line. The
    /// line's unit says "us"; for these series read it as bytes.
    public func record(bytes key: String, _ count: Int) {
        guard Self.isEnabled else { return }
        add(key, UInt64(max(count, 0)) * 1000)
        flushIfWindowElapsed()
    }

    /// Gap between consecutive pointer messages. This is the number that says
    /// whether stutter is arriving from the network or being created here.
    @inline(__always)
    public func recordMoveArrival() {
        guard Self.isEnabled else { return }
        let now = Self.now()
        let previous = lock.withLock { () -> UInt64 in
            let value = lastMoveArrival
            lastMoveArrival = now
            return value
        }
        if previous != 0 { add("arrival_gap", now &- previous) }
        flushIfWindowElapsed()
    }

    private func add(_ key: String, _ nanos: UInt64) {
        lock.withLock {
            var values = series[key] ?? []
            if values.count < maxSamples { values.append(nanos) }
            series[key] = values
        }
    }

    private func flushIfWindowElapsed() {
        let now = Self.now()
        let shouldFlush = lock.withLock { () -> Bool in
            guard now &- windowStart >= windowNanos else { return false }
            windowStart = now
            return true
        }
        guard shouldFlush else { return }

        let snapshot = lock.withLock { () -> [String: [UInt64]] in
            let copy = series
            series = [:]
            return copy
        }
        report(snapshot)
    }

    private func report(_ snapshot: [String: [UInt64]]) {
        for key in snapshot.keys.sorted() {
            guard let values = snapshot[key], !values.isEmpty else { continue }
            let sorted = values.sorted()
            let p50 = Double(sorted[sorted.count / 2]) / 1000
            let p95 = Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]) / 1000
            let max = Double(sorted[sorted.count - 1]) / 1000
            let mean = Double(sorted.reduce(0, &+)) / Double(sorted.count) / 1000
            Self.logger.info("""
                [perf] \(key, privacy: .public) n=\(sorted.count) \
                mean=\(mean, format: .fixed(precision: 1))us \
                p50=\(p50, format: .fixed(precision: 1))us \
                p95=\(p95, format: .fixed(precision: 1))us \
                max=\(max, format: .fixed(precision: 1))us
                """)
        }
    }
}
