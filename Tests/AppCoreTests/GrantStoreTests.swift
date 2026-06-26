// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
@testable import AppCore

@Suite("GrantStore", .serialized)
struct GrantStoreTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "grant-\(UUID().uuidString)")! }

    /// トークン再生成・編集トークン無効化が既定グラントへ反映され旧トークンが失効する（rotation 修復）。
    @Test func syncDefaultGrantsRotatesAndRevokes() {
        let d = suite()
        GrantStore.migrateIfNeeded(readToken: "R-old", editToken: "W-old", defaults: d)
        // R トークン再生成 → 旧 R 失効・新 R 有効
        GrantStore.syncDefaultGrants(readToken: "R-new", editToken: "W-old", defaults: d)
        #expect(GrantStore.find(token: "R-old", defaults: d) == nil)
        #expect(GrantStore.find(token: "R-new", defaults: d)?.tier == .read)
        // 編集トークン無効化 → default-edit 消滅（W 失効）
        GrantStore.syncDefaultGrants(readToken: "R-new", editToken: nil, defaults: d)
        #expect(GrantStore.find(token: "W-old", defaults: d) == nil)
        #expect(GrantStore.list(defaults: d).contains { $0.id == "default-edit" } == false)
        // 編集トークン再生成 → default-edit 復活
        GrantStore.syncDefaultGrants(readToken: "R-new", editToken: "W-new", defaults: d)
        #expect(GrantStore.find(token: "W-new", defaults: d)?.tier == .edit)
        // カスタムグラントは不変
        GrantStore.add(Grant(id: "fam", label: "家族", token: "FAM", tier: .read, scope: .libraries(["A"]), createdAt: Date(timeIntervalSince1970: 0)), defaults: d)
        GrantStore.syncDefaultGrants(readToken: "R-new2", editToken: "W-new", defaults: d)
        #expect(GrantStore.find(token: "FAM", defaults: d)?.id == "fam")
    }

    @Test func addFindDelete() {
        let d = suite()
        let g = Grant(id: "g1", label: "家族", token: "T1", tier: .read, scope: .libraries(["A"]), createdAt: Date(timeIntervalSince1970: 0))
        GrantStore.add(g, defaults: d)
        #expect(GrantStore.find(token: "T1", defaults: d)?.id == "g1")
        #expect(GrantStore.list(defaults: d).count == 1)
        GrantStore.delete(id: "g1", defaults: d)
        #expect(GrantStore.find(token: "T1", defaults: d) == nil)
    }
    @Test func scopeAllows() {
        #expect(GrantScope.all.allows("X"))
        #expect(GrantScope.libraries(["A"]).allows("A"))
        #expect(!GrantScope.libraries(["A"]).allows("B"))
    }
    @Test func migrateCreatesDefaultsOnce() {
        let d = suite()
        GrantStore.migrateIfNeeded(readToken: "R", editToken: "W", defaults: d)
        #expect(GrantStore.list(defaults: d).count == 2)
        GrantStore.migrateIfNeeded(readToken: "R", editToken: "W", defaults: d)
        #expect(GrantStore.list(defaults: d).count == 2)
        #expect(GrantStore.find(token: "R", defaults: d)?.tier == .read)
        #expect(GrantStore.find(token: "W", defaults: d)?.tier == .edit)
        #expect(GrantStore.find(token: "R", defaults: d)?.scope == .all)
    }
    @Test func grantScopeCodableRoundTrip() throws {
        for s in [GrantScope.all, .libraries(["A","B"])] {
            let back = try JSONDecoder().decode(GrantScope.self, from: JSONEncoder().encode(s))
            #expect(back == s)
        }
    }
}
