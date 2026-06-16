import Testing
import Foundation
@testable import AppCore

@Suite struct ServerPortTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    @Test func randomPortInRangeAndNotBlocked() {
        for _ in 0..<500 {
            let p = ServerPreferences.randomPort()
            #expect((1024...65535).contains(p))
            #expect(!ServerPreferences.blockedPorts.contains(p))
        }
    }
    @Test func portPersistsRandomOnFirstAccess() {
        let d = freshDefaults("port.first")
        let p1 = ServerPreferences.port(defaults: d)
        #expect((1024...65535).contains(p1))
        #expect(p1 != 8723)
        let p2 = ServerPreferences.port(defaults: d)
        #expect(p2 == p1)
    }
    @Test func storedPortRespected() {
        let d = freshDefaults("port.stored")
        ServerPreferences.setPort(40000, defaults: d)
        #expect(ServerPreferences.port(defaults: d) == 40000)
    }
    @Test func manualSetPortUnrestricted() {
        let d = freshDefaults("port.manual")
        ServerPreferences.setPort(80, defaults: d)
        #expect(ServerPreferences.port(defaults: d) == 80)
    }
}
