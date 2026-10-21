import Foundation

/// Runs a short-lived command and collects what it wrote.
enum Subprocess {
    struct Result {
        var ok: Bool
        var output: String
    }

    /// Drain before waiting so output larger than a pipe cannot deadlock.
    static func run(_ executableURL: URL,
                    _ arguments: [String],
                    input: Data? = nil,
                    timeout: TimeInterval = 5) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin.map { $0 as Any } ?? FileHandle.nullDevice
        // NSTask may outlive this call through its exit notifications. Release
        // descriptors now, rather than depending on Foundation's object lifetime.
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? stdin?.fileHandleForReading.close()
            try? stdin?.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            return Result(ok: false, output: error.localizedDescription)
        }
        try? output.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        if let input, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        var collected = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collected = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = drained.wait(timeout: .now() + 1)
            return Result(ok: false, output: "\(executableURL.lastPathComponent) timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()
        let text = String(data: collected, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(ok: process.terminationStatus == 0, output: text)
    }
}
