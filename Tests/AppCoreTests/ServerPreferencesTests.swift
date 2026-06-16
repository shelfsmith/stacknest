// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerPreferences (app-level server settings)")
struct ServerPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    /// 未設定時はランダムポートを生成して確定する（デフォルト8723廃止）。詳細は ServerPortTests。
    @Test func portRandomizedWhenUnset() {
        let d = freshDefaults()
        let p = ServerPreferences.port(defaults: d)
        #expect((1024...65535).contains(p))
        #expect(p != 8723)
    }

    /// 範囲外の保存値はランダムポートに置き換わる（有効範囲内）。
    @Test func portFallsBackToRandomWhenOutOfRange() {
        let d = freshDefaults()
        d.set(70000, forKey: ServerPreferences.portKey)
        let p = ServerPreferences.port(defaults: d)
        #expect((1024...65535).contains(p))
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
