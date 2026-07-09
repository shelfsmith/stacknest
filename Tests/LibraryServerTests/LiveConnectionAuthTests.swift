// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// G8a Important #1 fix: /events の長寿命接続再検証ヘルパの単体テスト。
/// grantsProvider が返す現在の grants に対し、接続時トークン/scope がまだ有効かを判定する。
@Suite("Live connection auth (SSE re-validation)")
struct LiveConnectionAuthTests {
    private func grant(token: String, scope: GrantScope) -> Grant {
        Grant(id: "g", label: "g", token: token, tier: .read, scope: scope, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func validGrantSameScopeStillAuthorized() {
        let g = grant(token: "TOK", scope: .all)
        #expect(liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .all, grants: [g]))
    }

    @Test func revokedGrantNoLongerAuthorized() {
        // トークンに一致する grant が grants から消えている＝取り消し済み。
        let other = grant(token: "OTHER", scope: .all)
        #expect(!liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .all, grants: [other]))
        #expect(!liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .all, grants: []))
    }

    @Test func scopeChangedNoLongerAuthorized() {
        // トークンは現存するが scope が接続時から縮小/変更された。
        let g = grant(token: "TOK", scope: .libraries(["lib-1"]))
        #expect(!liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .all, grants: [g]))
        #expect(!liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .libraries(["lib-2"]), grants: [g]))
        // scope が同一なら引き続き有効。
        #expect(liveConnectionStillAuthorized(presentedToken: "TOK", subscribedScope: .libraries(["lib-1"]), grants: [g]))
    }
}
