// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ServerConnectionStore — 接続履歴の永続化（token 平文）")
struct ServerConnectionStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.serverconn.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func addAndListRoundTripIncludingToken() {
        let store = ServerConnectionStore(defaults: freshDefaults())
        let c = ServerConnection(id: UUID(), displayName: "Mac A", baseURL: "http://192.168.0.2:8080/", token: "tok1")
        store.upsert(c)
        #expect(store.all().count == 1)
        #expect(store.all().first?.baseURL == "http://192.168.0.2:8080/")
        #expect(store.all().first?.token == "tok1")
    }

    @Test func upsertReplacesSameID() {
        let store = ServerConnectionStore(defaults: freshDefaults())
        let id = UUID()
        store.upsert(ServerConnection(id: id, displayName: "A", baseURL: "http://h:1/", token: "t1"))
        store.upsert(ServerConnection(id: id, displayName: "A2", baseURL: "http://h:2/", token: "t2"))
        #expect(store.all().count == 1)
        #expect(store.all().first?.displayName == "A2")
        #expect(store.all().first?.baseURL == "http://h:2/")
        #expect(store.all().first?.token == "t2")
    }

    @Test func removeDeletesEntry() {
        let store = ServerConnectionStore(defaults: freshDefaults())
        let id = UUID()
        store.upsert(ServerConnection(id: id, displayName: nil, baseURL: "http://h:1/", token: "t"))
        store.remove(id: id)
        #expect(store.all().isEmpty)
    }

    @Test func findByIDReturnsConnection() {
        let store = ServerConnectionStore(defaults: freshDefaults())
        let id = UUID()
        store.upsert(ServerConnection(id: id, displayName: nil, baseURL: "http://h:1/", token: "t"))
        #expect(store.connection(id: id)?.token == "t")
        #expect(store.connection(id: UUID()) == nil)
    }

    @Test("サーバ名は前後の空白を落とす")
    func normalizedDisplayNameTrimsWhitespace() {
        #expect(ServerConnection.normalizedDisplayName(input: "  マイサーバ  ", host: "192.168.1.10") == "マイサーバ")
    }

    @Test("空欄なら host にフォールバックする")
    func normalizedDisplayNameFallsBackToHost() {
        #expect(ServerConnection.normalizedDisplayName(input: "", host: "192.168.1.10") == "192.168.1.10")
    }

    @Test("空白だけの入力も空欄として扱う")
    func normalizedDisplayNameTreatsBlankAsEmpty() {
        #expect(ServerConnection.normalizedDisplayName(input: "   ", host: "192.168.1.10") == "192.168.1.10")
    }

    @Test("空欄かつ host も無ければ nil")
    func normalizedDisplayNameReturnsNilWithoutHost() {
        #expect(ServerConnection.normalizedDisplayName(input: "", host: nil) == nil)
    }
}
