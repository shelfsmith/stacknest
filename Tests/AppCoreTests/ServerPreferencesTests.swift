// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences (app-level server settings)")
struct ServerPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    /// 未設定時はデフォルトポートを返す。
    @Test func portDefaultsWhenUnset() {
        let d = freshDefaults()
        #expect(ServerPreferences.port(defaults: d) == ServerPreferences.defaultPort)
    }

    /// 範囲外の値はデフォルトに丸められる。
    @Test func portFallsBackWhenOutOfRange() {
        let d = freshDefaults()
        ServerPreferences.setPort(0, defaults: d)
        #expect(ServerPreferences.port(defaults: d) == ServerPreferences.defaultPort)
        ServerPreferences.setPort(70000, defaults: d)
        #expect(ServerPreferences.port(defaults: d) == ServerPreferences.defaultPort)
    }

    /// 有効範囲のポートはそのまま返る。
    @Test func portRoundTripsWhenValid() {
        let d = freshDefaults()
        ServerPreferences.setPort(9001, defaults: d)
        #expect(ServerPreferences.port(defaults: d) == 9001)
    }

    /// トークンは初回アクセスで生成され、以後は安定（同じ値）。
    @Test func tokenIsGeneratedThenStable() {
        let d = freshDefaults()
        let t1 = ServerPreferences.token(defaults: d)
        #expect(!t1.isEmpty)
        let t2 = ServerPreferences.token(defaults: d)
        #expect(t1 == t2)
    }

    /// base64url 形式（+ / = を含まない）。
    @Test func tokenIsBase64URLSafe() {
        let d = freshDefaults()
        let t = ServerPreferences.token(defaults: d)
        #expect(!t.contains("+"))
        #expect(!t.contains("/"))
        #expect(!t.contains("="))
    }

    /// 再生成で値が変わる。
    @Test func regenerateChangesToken() {
        let d = freshDefaults()
        let t1 = ServerPreferences.token(defaults: d)
        let t2 = ServerPreferences.regenerateToken(defaults: d)
        #expect(t1 != t2)
        #expect(ServerPreferences.token(defaults: d) == t2)
    }
}
