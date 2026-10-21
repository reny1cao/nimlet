import Foundation

/// An installed app copy. A nil path is a legacy target, resolved only when unambiguous.
public struct AppReference: Codable, Hashable, Sendable {
    public var bundleID: String
    public var applicationPath: String?

    public init(bundleID: String, applicationPath: String? = nil) {
        self.bundleID = bundleID
        self.applicationPath = applicationPath
    }

    public var key: String { bundleID.lowercased() + (applicationPath.map { "@" + $0 } ?? "") }
    public func matches(_ other: AppReference) -> Bool {
        bundleID.caseInsensitiveCompare(other.bundleID) == .orderedSame
            && (applicationPath == nil || other.applicationPath == nil || applicationPath == other.applicationPath)
    }
}

/// Issued by the host for one process lifetime, never inferred from a window title or PID alone.
public struct AppInstanceIdentity: Codable, Hashable, Sendable {
    public var hostSessionID: String
    public var instanceID: String
    public var processID: Int32
    public var app: AppReference
    public var launchEpochMillis: Int64? = nil

    public func identifiesSameProcess(as other: Self) -> Bool {
        guard processID == other.processID, app == other.app else { return false }
        if hostSessionID == other.hostSessionID { return instanceID == other.instanceID }
        guard let started = launchEpochMillis, let otherStarted = other.launchEpochMillis else { return false }
        return started == otherStarted
    }
}

public struct RunningMacApp: Codable, Hashable, Identifiable, Sendable {
    public var identity: AppInstanceIdentity
    public var name: String
    public var isActive: Bool
    public var isHidden: Bool
    public var id: String { identity.instanceID }
}

public struct AppRuntimeSnapshot: Codable, Equatable, Sendable {
    public var hostSessionID: String
    public var revision: Int
    public var apps: [RunningMacApp]
}

public struct AppCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case activate, reopen, focusWindow, restoreWindow, closeWindow, quit, keep, unkeep
        public var changesRunningContent: Bool { self != .keep && self != .unkeep }
    }
    public var id: String
    public var hostSessionID: String
    public var action: Action
    public var app: AppReference
    public var identity: AppInstanceIdentity?
    public var targetID: String?
    public var windowID: UInt32?

    public init(id: String = UUID().uuidString, hostSessionID: String, action: Action,
                app: AppReference, identity: AppInstanceIdentity? = nil,
                targetID: String? = nil, windowID: UInt32? = nil) {
        self.id = id
        self.hostSessionID = hostSessionID
        self.action = action
        self.app = app
        self.identity = identity
        self.targetID = targetID
        self.windowID = windowID
    }
}

public struct AppCommandResult: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case working, succeeded, failed, needsAttention, unconfirmed
    }
    public var requestID: String
    public var phase: Phase
    public var message: String
    public var targetID: String?
}

/// The network queue owns this ledger. Repeated packets cannot repeat a close or quit.
public struct AppCommandLedger {
    public enum Decision { case start, existing(AppCommandResult), conflict, busy }
    private struct Entry { var command: AppCommand; var result: AppCommandResult }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var retired: Set<String> = []
    private let limit: Int
    public init(limit: Int = 256) { self.limit = max(1, limit) }
    private func key(_ id: String, deviceID: String) -> String { deviceID + ":" + id }

    public mutating func begin(_ command: AppCommand, deviceID: String) -> Decision {
        let key = key(command.id, deviceID: deviceID)
        if let old = entries[key] {
            return old.command == command ? .existing(old.result) : .conflict
        }
        if retired.contains(key) {
            return .existing(AppCommandResult(requestID: command.id, phase: .unconfirmed,
                message: "That action was already handled. Refresh to check its result; it will not run again."))
        }
        guard retired.count < 32768,
              entries.values.filter({ $0.result.phase == .working }).count < 16 else { return .busy }
        if entries.count >= limit, let evict = order.first(where: { entries[$0]?.result.phase != .working }) {
            retired.insert(evict)
            entries.removeValue(forKey: evict)
            order.removeAll { $0 == evict }
        }
        entries[key] = Entry(command: command, result: AppCommandResult(
            requestID: command.id, phase: .working, message: "Waiting for your Mac", targetID: command.targetID))
        order.append(key)
        return .start
    }

    public mutating func finish(_ result: AppCommandResult, deviceID: String) {
        let key = key(result.requestID, deviceID: deviceID)
        entries[key]?.result = result
    }
}

extension NimletTarget {
    public var appReference: AppReference? {
        guard kind == .app, let bundleID else { return nil }
        return AppReference(bundleID: bundleID, applicationPath: applicationPath)
    }
}

extension MacApp {
    public var appReference: AppReference { AppReference(bundleID: bundleID, applicationPath: applicationPath) }
}
