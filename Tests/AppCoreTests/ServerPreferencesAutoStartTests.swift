// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences autoStartSharing")
struct ServerPreferencesAutoStartTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "autostart-\(UUID().uuidString)")! }

    @Test func defaultsFalse() {
        #expect(ServerPreferences.autoStartSharingOnLaunch(defaults: suite()) == false)
    }
    @Test func setAndGet() {
        let d = suite()
        ServerPreferences.setAutoStartSharingOnLaunch(true, defaults: d)
        #expect(ServerPreferences.autoStartSharingOnLaunch(defaults: d) == true)
        ServerPreferences.setAutoStartSharingOnLaunch(false, defaults: d)
        #expect(ServerPreferences.autoStartSharingOnLaunch(defaults: d) == false)
    }
}
