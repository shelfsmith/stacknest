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
    /// Process start time, in Unix epoch seconds.
    public var processStartTime: Double
    public var appInstanceUUID: String
    /// When the lock was first acquired, in Unix epoch seconds.
    public var acquiredAt: Double
    /// Last heartbeat refresh, in Unix epoch seconds.
    public var heartbeatAt: Double

    public init(schemaVersion: Int = LibraryOpenLock.currentSchemaVersion, hostUUID: String, hostName: String, pid: Int32,
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
    public static let currentSchemaVersion = 1
    public static let heartbeatInterval: TimeInterval = 30
    /// A remote lock is considered stale after 3 missed heartbeats (tolerate 2 dropped beats).
    public static let staleThreshold: TimeInterval = heartbeatInterval * 3

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

    /// `bundleURL` is the `.stacknest` package directory itself; the lock lives INSIDE the bundle.
    public static func lockFileURL(bundleURL: URL) -> URL {
        bundleURL.appending(path: fileName)
    }

    public static func readLock(bundleURL: URL) -> LibraryOpenLockInfo? {
        let url = lockFileURL(bundleURL: bundleURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Decode failure → nil → treated as absent/stale (acquirable). Forward-compat hazard:
        // a newer schemaVersion lock an older build cannot decode is treated as absent, so an
        // older build may reclaim it. Discriminating decode (read schemaVersion first) is a
        // conscious deferral, out of scope for now.
        return try? JSONDecoder().decode(LibraryOpenLockInfo.self, from: data)
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
    ///
    /// Advisory only: the read→write window is NOT atomic, so two near-simultaneous opens on a
    /// shared volume can race past each other. This is a best-effort conflict warning, not a hard mutex.
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
