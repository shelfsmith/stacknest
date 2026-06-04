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
