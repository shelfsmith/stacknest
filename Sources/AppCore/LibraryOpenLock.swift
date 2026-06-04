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
