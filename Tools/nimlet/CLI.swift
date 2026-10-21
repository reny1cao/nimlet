import Foundation

/// A failure with an exit code attached, so every path out of the tool ends in
/// a number a script can branch on rather than a bare 1.
struct CLIError: Error {
    enum Code: Int32 {
        /// The host refused, or a delivery came back not ok.
        case refused = 1
        /// Bad arguments, unknown target, nothing paired yet.
        case usage = 2
        /// No host found, or the connection never came up.
        case unreachable = 3
        /// Connected, but nothing came back in time.
        case timedOut = 4
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// A small scanner that pulls named options out of the argument list and leaves
/// the rest positional, so `nimlet send --target x "text"` and
/// `nimlet send "text" --target x` both work.
struct Arguments {
    private var tokens: [String]

    init(_ tokens: [String]) { self.tokens = tokens }

    var isEmpty: Bool { tokens.isEmpty }

    mutating func flag(_ name: String, _ alias: String? = nil) -> Bool {
        guard let index = index(of: name, alias) else { return false }
        tokens.remove(at: index)
        return true
    }

    mutating func option(_ name: String, _ alias: String? = nil) throws -> String? {
        if let index = tokens.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            return String(tokens.remove(at: index).dropFirst(name.count + 1))
        }
        guard let index = index(of: name, alias) else { return nil }
        let flag = tokens.remove(at: index)
        guard index < tokens.count, !tokens[index].hasPrefix("--") else {
            throw CLIError(.usage, "\(flag) needs a value")
        }
        return tokens.remove(at: index)
    }

    /// Options are consumed before this is called, so anything left that does
    /// not look like one is the command or its argument.
    mutating func takePositional() -> String? {
        guard let index = tokens.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return tokens.remove(at: index)
    }

    func finish() throws {
        guard let leftover = tokens.first else { return }
        throw CLIError(.usage, "unexpected argument: \(leftover)")
    }

    private func index(of name: String, _ alias: String?) -> Int? {
        tokens.firstIndex { $0 == name || $0 == alias }
    }
}

/// Everything the tool prints. Results go to stdout so they can be piped;
/// warnings and failures go to stderr so they never corrupt `--json` output.
enum Output {
    static var json = false

    private static let compact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private struct Failure: Encodable {
        let ok = false
        let error: String
    }

    /// Human-readable result. Suppressed under `--json`, where the machine
    /// output is the result.
    static func say(_ text: String) {
        guard !json else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data(("nimlet: " + text + "\n").utf8))
    }

    static func fail(_ message: String) {
        guard json else {
            FileHandle.standardError.write(Data(("nimlet: " + message + "\n").utf8))
            return
        }
        guard var data = try? compact.encode(Failure(error: message)) else {
            FileHandle.standardError.write(Data(("nimlet: " + message + "\n").utf8))
            return
        }
        data.append(0x0A)
        FileHandle.standardError.write(data)
    }

    static func emit<T: Encodable>(_ value: T) {
        guard json, var data = try? compact.encode(value) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// Percentile summary of a set of timing samples.
struct Stat: Encodable {
    let samples: Int
    let mean: Double
    let p50: Double
    let p95: Double
    let max: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        samples = sorted.count
        mean = sorted.reduce(0, +) / Double(sorted.count)
        p50 = sorted[sorted.count / 2]
        p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        max = sorted[sorted.count - 1]
    }

    func line(label: String, unit: String) -> String {
        let name = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        func number(_ value: Double) -> String { String(format: "%.1f", value) }
        return "  \(name) n=\(samples) mean=\(number(mean))\(unit)"
            + " p50=\(number(p50))\(unit) p95=\(number(p95))\(unit) max=\(number(max))\(unit)"
    }
}
