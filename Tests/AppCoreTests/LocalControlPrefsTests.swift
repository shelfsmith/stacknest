// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences local control", .serialized)
struct LocalControlPrefsTests {
    @Test func tokenPersistsAndPortStable() {
        UserDefaults.standard.removeObject(forKey: "local_control_token")
        UserDefaults.standard.removeObject(forKey: "local_control_port")
        let t1 = ServerPreferences.localControlToken()
        #expect(!t1.isEmpty)
        #expect(ServerPreferences.localControlToken() == t1)
        let p1 = ServerPreferences.localControlPort()
        #expect(p1 > 0)
        #expect(ServerPreferences.localControlPort() == p1)
        let t2 = ServerPreferences.regenerateLocalControlToken()
        #expect(t2 != t1)
    }
    @Test func enabledDefaultsTrue() {
        UserDefaults.standard.removeObject(forKey: "local_automation_enabled")
        #expect(ServerPreferences.localAutomationEnabled() == true)
    }
}
