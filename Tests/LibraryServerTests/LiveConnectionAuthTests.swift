// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// G8a Important #1 fix: /events の長寿命接続再検証ヘルパの単体テスト。
/// grantsProvider が返す現在の grants に対し、接続時の principal/scope がまだ有効かを判定する。
///
/// G23 (#9/#10) Codex High #1: 判定基準を「提示トークン文字列の一致」から
/// **接続時に認証された grant id** に変更した。クエリに載るのが短命セッショントークンに
/// なったため、トークン文字列の比較では正規の接続でも必ず失敗していた（≒5 秒ごとに切断）。
@Suite("Live connection auth (SSE re-validation)")
struct LiveConnectionAuthTests {
    private func grant(id: String = "g", token: String, scope: GrantScope) -> Grant {
        Grant(id: id, label: "g", token: token, tier: .read, scope: scope, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func validGrantSameScopeStillAuthorized() {
        let g = grant(token: "TOK", scope: .all)
        #expect(liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [g]))
    }

    @Test func revokedGrantNoLongerAuthorized() {
        // id に一致する grant が grants から消えている＝取り消し済み。
        let other = grant(id: "other", token: "OTHER", scope: .all)
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [other]))
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: []))
    }

    @Test func scopeChangedNoLongerAuthorized() {
        // grant は現存するが scope が接続時から縮小/変更された。
        let g = grant(token: "TOK", scope: .libraries(["lib-1"]))
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [g]))
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .libraries(["lib-2"]), grants: [g]))
        // scope が同一なら引き続き有効。
        #expect(liveConnectionStillAuthorized(grantID: "g", subscribedScope: .libraries(["lib-1"]), grants: [g]))
    }

    // MARK: - G23 Codex High #1 の回帰テスト

    /// **本命の回帰**: 接続がセッショントークン経由でも、grant が生きている限り再認証は通り続ける。
    /// 修正前はここで grant token 文字列と比較していたため false になり、ハートビート毎に切断していた。
    @Test func sessionTokenBackedConnectionSurvivesHeartbeat() {
        let g = grant(token: "PERSISTENT-GRANT-TOKEN", scope: .all)
        // クライアントが提示したのは短命セッショントークンで、grant token とは別値。
        // 判定は grant id で行うので、トークンの種類に依存しない。
        #expect(liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [g]))
        // 何度呼んでも安定して true（ハートビートは 5 秒ごとに繰り返し呼ぶ）。
        for _ in 0..<3 {
            #expect(liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [g]))
        }
    }

    /// grant を削除したら、セッショントークン経由の接続も終了する（即時失効が効く）。
    @Test func sessionTokenBackedConnectionEndsWhenGrantDeleted() {
        let g = grant(token: "PERSISTENT-GRANT-TOKEN", scope: .all)
        #expect(liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [g]))
        // 管理者が grant を削除 → 以後は false。
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: []))
    }

    /// 同じ token 値を持つ別 id の grant があっても、id が違えば通さない。
    @Test func matchingTokenWithDifferentIDIsNotAuthorized() {
        let impostor = grant(id: "another", token: "TOK", scope: .all)
        #expect(!liveConnectionStillAuthorized(grantID: "g", subscribedScope: .all, grants: [impostor]))
    }
}
