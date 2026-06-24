// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences cli_path")
struct CLIPathPrefsTests {
    @Test func setAndGet() throws {
        // standard を汚さないよう専用 suite を注入（他テスト/実環境への副作用なし）。
        let suiteName = "cli-path-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ServerPreferences.cliPath(defaults: defaults) == nil)
        ServerPreferences.setCLIPath("/Applications/StackNest.app/Contents/Helpers/stacknest-cli", defaults: defaults)
        #expect(ServerPreferences.cliPath(defaults: defaults) == "/Applications/StackNest.app/Contents/Helpers/stacknest-cli")
        ServerPreferences.setCLIPath(nil, defaults: defaults)
        #expect(ServerPreferences.cliPath(defaults: defaults) == nil)
    }
}
