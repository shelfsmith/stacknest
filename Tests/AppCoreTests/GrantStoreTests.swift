// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
@testable import AppCore

@Suite("GrantStore", .serialized)
struct GrantStoreTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "grant-\(UUID().uuidString)")! }
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
