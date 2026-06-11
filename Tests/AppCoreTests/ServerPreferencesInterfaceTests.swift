// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences preferredInterface")
struct ServerPreferencesInterfaceTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.prefIface.\(UUID().uuidString)")!
    }
    @Test func defaultsToNil() {
        #expect(ServerPreferences.preferredInterface(defaults: freshDefaults()) == nil)
    }
    @Test func roundTrips() {
        let d = freshDefaults()
        ServerPreferences.setPreferredInterface("en0", defaults: d)
        #expect(ServerPreferences.preferredInterface(defaults: d) == "en0")
        ServerPreferences.setPreferredInterface(nil, defaults: d)
        #expect(ServerPreferences.preferredInterface(defaults: d) == nil)
    }
}
