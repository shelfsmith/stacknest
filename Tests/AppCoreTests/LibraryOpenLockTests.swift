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

    private func tempBundle() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lock-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func acquireOnEmptyWritesLock() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let mine = Self.sample(instance: "INST-1", host: "HOST-A")
        let outcome = LibraryOpenLock.acquire(bundleURL: bundle, ourInfo: mine, now: 6000, isPidAlive: { _, _ in true })
        #expect(outcome == .acquired)
        let onDisk = LibraryOpenLock.readLock(bundleURL: bundle)
        #expect(onDisk?.appInstanceUUID == "INST-1")
    }

    @Test
    func acquireWithLiveOtherHostReturnsConflict() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let other = Self.sample(instance: "OTHER", host: "HOST-B", heartbeat: 5990)
        try JSONEncoder().encode(other).write(to: LibraryOpenLock.lockFileURL(bundleURL: bundle))
        let mine = Self.sample(instance: "INST-1", host: "HOST-A")
        let outcome = LibraryOpenLock.acquire(bundleURL: bundle, ourInfo: mine, now: 6000, isPidAlive: { _, _ in true })
        #expect(outcome == .conflict(other))
        // existing lock untouched
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.appInstanceUUID == "OTHER")
    }

    @Test
    func acquireReclaimsStaleOtherHost() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let other = Self.sample(instance: "OTHER", host: "HOST-B", heartbeat: 5000) // very old
        try JSONEncoder().encode(other).write(to: LibraryOpenLock.lockFileURL(bundleURL: bundle))
        let mine = Self.sample(instance: "INST-1", host: "HOST-A")
        let outcome = LibraryOpenLock.acquire(bundleURL: bundle, ourInfo: mine, now: 6000, isPidAlive: { _, _ in true })
        #expect(outcome == .acquired)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.appInstanceUUID == "INST-1")
    }

    @Test
    func forceAcquireOverwrites() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let other = Self.sample(instance: "OTHER", host: "HOST-B", heartbeat: 5990)
        try JSONEncoder().encode(other).write(to: LibraryOpenLock.lockFileURL(bundleURL: bundle))
        let mine = Self.sample(instance: "INST-1", host: "HOST-A")
        LibraryOpenLock.forceAcquire(bundleURL: bundle, ourInfo: mine)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.appInstanceUUID == "INST-1")
    }

    @Test
    func heartbeatUpdatesOwnOnly() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let mine = Self.sample(instance: "INST-1", host: "HOST-A", heartbeat: 6000)
        try JSONEncoder().encode(mine).write(to: LibraryOpenLock.lockFileURL(bundleURL: bundle))
        #expect(LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "INST-1", now: 6100) == true)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.heartbeatAt == 6100)
        // not ours → false, unchanged
        #expect(LibraryOpenLock.heartbeat(bundleURL: bundle, instanceUUID: "OTHER", now: 6200) == false)
        #expect(LibraryOpenLock.readLock(bundleURL: bundle)?.heartbeatAt == 6100)
    }

    @Test
    func releaseDeletesOwnOnly() throws {
        let bundle = tempBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let other = Self.sample(instance: "OTHER", host: "HOST-B")
        try JSONEncoder().encode(other).write(to: LibraryOpenLock.lockFileURL(bundleURL: bundle))
        LibraryOpenLock.release(bundleURL: bundle, instanceUUID: "INST-1") // not ours → no-op
        #expect(LibraryOpenLock.readLock(bundleURL: bundle) != nil)
        LibraryOpenLock.release(bundleURL: bundle, instanceUUID: "OTHER") // ours → deleted
        #expect(LibraryOpenLock.readLock(bundleURL: bundle) == nil)
    }

    @Test
    func acquireOnReadOnlyDirIsUnprotected() throws {
        // Non-existent parent makes the write fail → .unprotected (open without lock).
        let bundle = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)/nested")
        let mine = Self.sample(instance: "INST-1", host: "HOST-A")
        let outcome = LibraryOpenLock.acquire(bundleURL: bundle, ourInfo: mine, now: 6000, isPidAlive: { _, _ in true })
        #expect(outcome == .unprotected)
    }
}
