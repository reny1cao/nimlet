import Combine
import Foundation

/// Which phones the user has actually said yes to.
///
/// A pairing code is six characters — about thirty bits — and it gets read
/// aloud, photographed and left on screen. Completing the TLS handshake
/// therefore proves that someone knows the code, not that they are the person
/// sitting at this Mac, and what is on the other end of the handshake can type
/// into it. So the handshake only buys a connection: nothing is injected for a
/// device until its id appears in `approved`.
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()

    struct Device: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var lastSeen: Date
    }

    private let approvedKey = "mice.devices.approved.v1"
    private let revokedKey = "mice.devices.revoked.v1"

    @Published private(set) var approved: [Device] = []
    /// A rejected device is remembered rather than forgotten, so it cannot come
    /// back a minute later looking like a stranger the user has never ruled on.
    @Published private(set) var revoked: [Device] = []

    /// `isApproved` is consulted for every inbound message on the network
    /// queue, while the lists are edited from the menu bar on main.
    private let lock = NSLock()
    private var approvedIDs: Set<String> = []
    private var revokedIDs: Set<String> = []

    private init() {
        approved = DeviceRegistry.load(key: approvedKey).filter(DeviceRegistry.isCurrent)
        revoked = DeviceRegistry.load(key: revokedKey).filter(DeviceRegistry.isCurrent)
        approvedIDs = Set(approved.map(\.id))
        revokedIDs = Set(revoked.map(\.id))
        persist()
    }

    /// A phone paired by key, whose id is its key's 32-byte fingerprint in
    /// base64url, or a copy of the nimlet tool. Anything else is a phone from the
    /// pairing-code days: it can no longer connect, and only cluttered the menu
    /// with a second entry under the same name.
    static func isCurrent(_ device: Device) -> Bool {
        if device.name == toolName { return true }
        let base64URL = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return device.id.count == 43 && device.id.unicodeScalars.allSatisfy(base64URL.contains)
    }

    /// What every copy of the nimlet tool calls itself.
    static let toolName = "nimlet CLI"

    func isApproved(_ deviceID: String) -> Bool {
        lock.withLock { approvedIDs.contains(deviceID) }
    }

    /// Every approved device, for building the away listener's key list. Off the
    /// lock rather than off `approved`, because the listener is built on the
    /// network queue and `approved` is edited on main.
    func approvedIdentifiers() -> [String] {
        lock.withLock { Array(approvedIDs) }
    }

    func isRevoked(_ deviceID: String) -> Bool {
        lock.withLock { revokedIDs.contains(deviceID) }
    }

    /// Records that a device connected, and answers whether it may be obeyed.
    @discardableResult
    func seen(deviceID: String, name: String) -> Bool {
        let approved = isApproved(deviceID)
        DispatchQueue.main.async { self.touch(deviceID: deviceID, name: name) }
        return approved
    }

    func approve(deviceID: String, name: String) {
        lock.withLock {
            _ = revokedIDs.remove(deviceID)
            _ = approvedIDs.insert(deviceID)
        }
        revoked.removeAll { $0.id == deviceID }
        let device = Device(id: deviceID, name: name, lastSeen: Date())
        if let index = approved.firstIndex(where: { $0.id == deviceID }) {
            approved[index] = device
        } else {
            approved.append(device)
        }
        persist()
    }

    /// Approves from the network queue, for a phone that has just proved it
    /// scanned this Mac's QR code.
    ///
    /// The id sets change now, under the lock, because the very next line on
    /// that socket is its `hello` and it must find the device approved. The
    /// published lists are the menu's, and they follow on main.
    func approveFromNetwork(deviceID: String, name: String) {
        lock.withLock {
            _ = revokedIDs.remove(deviceID)
            _ = approvedIDs.insert(deviceID)
        }
        DispatchQueue.main.async { self.approve(deviceID: deviceID, name: name) }
    }

    func revoke(deviceID: String) {
        lock.withLock {
            _ = approvedIDs.remove(deviceID)
            _ = revokedIDs.insert(deviceID)
        }
        let name = approved.first { $0.id == deviceID }?.name
            ?? revoked.first { $0.id == deviceID }?.name
            ?? "iPhone"
        approved.removeAll { $0.id == deviceID }
        revoked.removeAll { $0.id == deviceID }
        revoked.append(Device(id: deviceID, name: name, lastSeen: Date()))
        persist()
    }

    func forget(deviceID: String) {
        lock.withLock { _ = revokedIDs.remove(deviceID) }
        revoked.removeAll { $0.id == deviceID }
        persist()
    }

    private func touch(deviceID: String, name: String) {
        if let index = approved.firstIndex(where: { $0.id == deviceID }) {
            approved[index].name = name
            approved[index].lastSeen = Date()
            persist()
        } else if let index = revoked.firstIndex(where: { $0.id == deviceID }) {
            revoked[index].name = name
            revoked[index].lastSeen = Date()
            persist()
        }
    }

    private func persist() {
        write(approved, key: approvedKey)
        write(revoked, key: revokedKey)
    }

    private func write(_ devices: [Device], key: String) {
        guard let data = try? NimletCoder.line(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load(key: String) -> [Device] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try NimletCoder.decode([Device].self, from: data)
        } catch {
            // Starting over silently meant every approval vanished without a
            // word and every phone asked to be approved again. The bytes are
            // kept under a sibling key, so they can at least be looked at.
            // `print`, not `miceLog`: this file is compiled into the test
            // bundle on its own, where the host's logger does not exist.
            print("device registry: \(key) is unreadable (\(error.localizedDescription)); kept as \(key).unreadable")
            UserDefaults.standard.set(data, forKey: key + ".unreadable")
            return []
        }
    }
}
