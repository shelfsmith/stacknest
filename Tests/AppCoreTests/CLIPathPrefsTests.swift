// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences cli_path", .serialized)
struct CLIPathPrefsTests {
    @Test func setAndGet() {
        UserDefaults.standard.removeObject(forKey: "cli_path")
        #expect(ServerPreferences.cliPath() == nil)
        ServerPreferences.setCLIPath("/Applications/StackNest.app/Contents/Helpers/stacknest-cli")
        #expect(ServerPreferences.cliPath() == "/Applications/StackNest.app/Contents/Helpers/stacknest-cli")
        ServerPreferences.setCLIPath(nil)
        #expect(ServerPreferences.cliPath() == nil)
    }
}
