// SPDX-License-Identifier: MIT
import Foundation

/// On-disk content of `<bundle>.stacknest/.openlock.json`.
/// Identifies which app instance currently holds the library open, for
/// cross-Mac concurrent-open detection (Phase 2.6d).
public struct LibraryOpenLockInfo: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var hostUUID: String
    public var hostName: String
    public var pid: Int32
    public var processStartTime: Double
    public var appInstanceUUID: String
    public var acquiredAt: Double
    public var heartbeatAt: Double

    public init(schemaVersion: Int = 1, hostUUID: String, hostName: String, pid: Int32,
                processStartTime: Double, appInstanceUUID: String, acquiredAt: Double, heartbeatAt: Double) {
        self.schemaVersion = schemaVersion
        self.hostUUID = hostUUID
        self.hostName = hostName
        self.pid = pid
        self.processStartTime = processStartTime
        self.appInstanceUUID = appInstanceUUID
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
    }
}

public enum LibraryOpenLockStatus: Equatable, Sendable {
    case acquirable
    case heldByThisInstance
    case conflictSameHost(LibraryOpenLockInfo)
    case conflictOtherHost(LibraryOpenLockInfo)
}

public enum LibraryOpenLock {
    public static let heartbeatInterval: TimeInterval = 30
    public static let staleThreshold: TimeInterval = 90

    /// Decide what to do given the existing lock (if any) and our environment.
    /// `isPidAlive(pid, recordedStartTime)` is supplied by the App layer.
    public static func evaluate(
        existing: LibraryOpenLockInfo?,
        ourHostUUID: String,
        ourInstanceUUID: String,
        now: Double,
        isPidAlive: (_ pid: Int32, _ recordedStartTime: Double) -> Bool
    ) -> LibraryOpenLockStatus {
        guard let existing else { return .acquirable }
        if existing.appInstanceUUID == ourInstanceUUID { return .heldByThisInstance }
        if existing.hostUUID == ourHostUUID {
            // Same Mac: PID liveness is authoritative (instant crash recovery).
            return isPidAlive(existing.pid, existing.processStartTime)
                ? .conflictSameHost(existing) : .acquirable
        }
        // Other Mac: cannot check remote PID, rely on heartbeat freshness.
        return (now - existing.heartbeatAt <= staleThreshold)
            ? .conflictOtherHost(existing) : .acquirable
    }
}

public enum LibraryOpenLockOutcome: Equatable, Sendable {
    case acquired
    case conflict(LibraryOpenLockInfo)
    case unprotected   // lock file could not be written (e.g. read-only volume); open without protection
}

extension LibraryOpenLock {
    public static let fileName = ".openlock.json"

    public static func lockFileURL(bundleURL: URL) -> URL {
        bundleURL.appending(path: fileName)
    }

    public static func readLock(bundleURL: URL) -> LibraryOpenLockInfo? {
        let url = lockFileURL(bundleURL: bundleURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryOpenLockInfo.self, from: data)  // corrupt → nil → treated as stale
    }

    private static func write(_ info: LibraryOpenLockInfo, bundleURL: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(info) else { return false }
        do {
            try data.write(to: lockFileURL(bundleURL: bundleURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read+evaluate+write. Writes our lock when acquirable/held; returns `.conflict` otherwise,
    /// and `.unprotected` when the lock file cannot be written.
    public static func acquire(
        bundleURL: URL,
        ourInfo: LibraryOpenLockInfo,
        now: Double,
        isPidAlive: (_ pid: Int32, _ recordedStartTime: Double) -> Bool
    ) -> LibraryOpenLockOutcome {
        let existing = readLock(bundleURL: bundleURL)
        let status = evaluate(existing: existing, ourHostUUID: ourInfo.hostUUID,
                              ourInstanceUUID: ourInfo.appInstanceUUID, now: now, isPidAlive: isPidAlive)
        switch status {
        case .acquirable, .heldByThisInstance:
            return write(ourInfo, bundleURL: bundleURL) ? .acquired : .unprotected
        case .conflictSameHost(let info), .conflictOtherHost(let info):
            return .conflict(info)
        }
    }

    /// Overwrite the lock unconditionally (user chose "force open").
    @discardableResult
    public static func forceAcquire(bundleURL: URL, ourInfo: LibraryOpenLockInfo) -> Bool {
        write(ourInfo, bundleURL: bundleURL)
    }

    /// Refresh `heartbeatAt` only if we still own the lock. Returns false if we lost it.
    @discardableResult
    public static func heartbeat(bundleURL: URL, instanceUUID: String, now: Double) -> Bool {
        guard var info = readLock(bundleURL: bundleURL), info.appInstanceUUID == instanceUUID else { return false }
        info.heartbeatAt = now
        return write(info, bundleURL: bundleURL)
    }

    /// Delete the lock only if we own it (never remove someone else's lock).
    public static func release(bundleURL: URL, instanceUUID: String) {
        guard let info = readLock(bundleURL: bundleURL), info.appInstanceUUID == instanceUUID else { return }
        try? FileManager.default.removeItem(at: lockFileURL(bundleURL: bundleURL))
    }
}
