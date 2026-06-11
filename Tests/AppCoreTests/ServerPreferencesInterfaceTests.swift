// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences preferredHostIP")
struct ServerPreferencesHostIPTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.prefHostIP.\(UUID().uuidString)")!
    }
    @Test func defaultsToNil() {
        #expect(ServerPreferences.preferredHostIP(defaults: freshDefaults()) == nil)
    }
    @Test func roundTrips() {
        let d = freshDefaults()
        ServerPreferences.setPreferredHostIP("192.168.1.5", defaults: d)
        #expect(ServerPreferences.preferredHostIP(defaults: d) == "192.168.1.5")
        ServerPreferences.setPreferredHostIP(nil, defaults: d)
        #expect(ServerPreferences.preferredHostIP(defaults: d) == nil)
    }
}
