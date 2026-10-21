import Foundation

/// What `nimlet pair` writes and every other command reads.
struct Config: Codable {
    var pairingCode: String
    /// Bonjour service name of the Mac to dial. nil means "whichever one is
    /// advertising, as long as there is only one".
    var hostName: String?
    /// Generated once and kept. The Mac approves and revokes *devices*, so a CLI
    /// that invented a new id per run would ask to be approved on every send.
    var deviceID: String

    /// Shown in the Mac's connected-devices list.
    static let deviceName = "nimlet CLI"

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("nimlet", isDirectory: true)
    static let url = directory.appendingPathComponent("config.json")

    static func fresh() -> Config {
        Config(pairingCode: "", hostName: nil, deviceID: UUID().uuidString)
    }

    static func load() throws -> Config {
        guard let data = try? Data(contentsOf: url) else {
            throw CLIError(.usage, "not paired yet — run `nimlet pair --code ABC123` with the code from Nimlet Settings → Agents")
        }
        guard let config = try? JSONDecoder().decode(Config.self, from: data), !config.pairingCode.isEmpty else {
            throw CLIError(.usage, "\(url.path) is unreadable — run `nimlet pair --code ABC123` again")
        }
        return config
    }

    func save() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: Config.directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(self)
            data.append(0x0A)
            try data.write(to: Config.url, options: .atomic)
            // An atomic write swaps in a newly created file, so permissions set
            // on the previous one do not survive it. This holds the pairing
            // code, which is the only thing between a stranger on the Wi-Fi and
            // keystroke injection, so narrow it after every write.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.url.path)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(.usage, "could not write \(Config.url.path): \(error.localizedDescription)")
        }
    }
}
