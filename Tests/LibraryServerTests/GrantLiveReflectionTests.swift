// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// 稼働中のグラント変更をシミュレートする可変ボックス（@Sendable provider 用）。
private final class GrantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [Grant]
    init(_ grants: [Grant]) { self.grants = grants }
    func snapshot() -> [Grant] { lock.lock(); defer { lock.unlock() }; return grants }
    func set(_ g: [Grant]) { lock.lock(); grants = g; lock.unlock() }
}

@Suite("Grant live reflection")
struct GrantLiveReflectionTests {
    private func makeApp(box: GrantBox, libs: [ServedLibrary]) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "unused", editToken: nil,
                          grantsProvider: { box.snapshot() }),
            dataSource: StaticLibraryDataSource(libraries: libs)
        ).buildApplication()
    }
    private func readGrant(_ token: String, scope: GrantScope = .all, tier: AccessTier = .read) -> Grant {
        Grant(id: "g-\(token)", label: "t", token: token, tier: tier, scope: scope,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    /// 起動後に追加したグラントのトークンが次リクエストで有効になる。
    @Test func liveAdd() async throws {
        let fa = try TestLibraryFixture(name: "LA", bookCount: 1); defer { fa.cleanup() }
        let box = GrantBox([readGrant("OLD")])
        try await makeApp(box: box, libs: [fa.servedLibrary()]).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer NEW"]) { r in
                #expect(r.status == .unauthorized)
            }
            box.set([readGrant("OLD"), readGrant("NEW")])
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer NEW"]) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// グラント削除でトークンが即時失効（次リクエスト 401）。
    @Test func immediateRevocation() async throws {
        let fa = try TestLibraryFixture(name: "LR", bookCount: 1); defer { fa.cleanup() }
        let box = GrantBox([readGrant("TK")])
        try await makeApp(box: box, libs: [fa.servedLibrary()]).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                #expect(r.status == .ok)
            }
            box.set([])
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }

    /// scope 変更が即反映（庫 B が一覧から消え直接アクセス 404）。
    @Test func scopeChangeLive() async throws {
        let fa = try TestLibraryFixture(name: "SA", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "SB", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let box = GrantBox([readGrant("TK", scope: .all)])
        try await makeApp(box: box, libs: [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                let dto = try JSONDecoder().decode([LibraryDTO].self, from: r.body)
                #expect(dto.count == 2)
            }
            box.set([readGrant("TK", scope: .libraries([a.uuid]))])
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                let dto = try JSONDecoder().decode([LibraryDTO].self, from: r.body)
                #expect(dto.count == 1); #expect(dto.first?.id == a.uuid)
            }
            try await client.execute(uri: "/api/v1/libraries/\(b.uuid)/books", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                #expect(r.status == .notFound)
            }
        }
    }

    /// tier 昇格が即反映（/me の tier が read→edit）。
    @Test func tierChangeLive() async throws {
        let fa = try TestLibraryFixture(name: "TA", bookCount: 1); defer { fa.cleanup() }
        let box = GrantBox([readGrant("TK", tier: .read)])
        try await makeApp(box: box, libs: [fa.servedLibrary()]).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.tier == .read)
            }
            box.set([readGrant("TK", tier: .edit)])
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer TK"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.tier == .edit)
            }
        }
    }
}
