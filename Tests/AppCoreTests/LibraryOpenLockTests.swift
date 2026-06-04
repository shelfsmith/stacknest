import Testing
import Foundation
@testable import AppCore

@Suite("LibraryOpenLock")
struct LibraryOpenLockTests {
    static func sample(instance: String = "INST-1", host: String = "HOST-A",
                       pid: Int32 = 100, start: Double = 1000, heartbeat: Double = 5000) -> LibraryOpenLockInfo {
        LibraryOpenLockInfo(schemaVersion: 1, hostUUID: host, hostName: "Mac-A",
                            pid: pid, processStartTime: start, appInstanceUUID: instance,
                            acquiredAt: 4000, heartbeatAt: heartbeat)
    }

    @Test
    func codableRoundTrip() throws {
        let info = Self.sample()
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(LibraryOpenLockInfo.self, from: data)
        #expect(decoded == info)
    }

    @Test
    func evaluateNilIsAcquirable() {
        let s = LibraryOpenLock.evaluate(existing: nil, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in true })
        #expect(s == .acquirable)
    }

    @Test
    func evaluateOwnInstanceIsHeld() {
        let info = Self.sample(instance: "INST-1")
        let s = LibraryOpenLock.evaluate(existing: info, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in true })
        #expect(s == .heldByThisInstance)
    }

    @Test
    func evaluateSameHostPidAliveIsConflict() {
        let info = Self.sample(instance: "OTHER", host: "HOST-A")
        let s = LibraryOpenLock.evaluate(existing: info, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in true })
        #expect(s == .conflictSameHost(info))
    }

    @Test
    func evaluateSameHostPidDeadIsAcquirable() {
        let info = Self.sample(instance: "OTHER", host: "HOST-A")
        let s = LibraryOpenLock.evaluate(existing: info, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in false })
        #expect(s == .acquirable)
    }

    @Test
    func evaluateOtherHostFreshHeartbeatIsConflict() {
        let info = Self.sample(instance: "OTHER", host: "HOST-B", heartbeat: 5950) // now-50 <= 90
        let s = LibraryOpenLock.evaluate(existing: info, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in true })
        #expect(s == .conflictOtherHost(info))
    }

    @Test
    func evaluateOtherHostStaleHeartbeatIsAcquirable() {
        let info = Self.sample(instance: "OTHER", host: "HOST-B", heartbeat: 5800) // now-200 > 90
        let s = LibraryOpenLock.evaluate(existing: info, ourHostUUID: "HOST-A", ourInstanceUUID: "INST-1",
                                         now: 6000, isPidAlive: { _, _ in true })
        #expect(s == .acquirable)
    }
}
