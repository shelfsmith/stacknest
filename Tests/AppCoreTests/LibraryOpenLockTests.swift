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
}
