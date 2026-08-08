// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("integrity endpoints (G27a)")
struct IntegrityEndpointTests {
    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    @Test("summary は検査前でも 200 を返し未検査数を報告する")
    func summaryBeforeAnyScan() async throws {
        let fixture = try TestLibraryFixture(name: "IntegSummary", bookCount: 3)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/summary",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let reply = try JSONDecoder().decode(
                    IntegritySummaryReply.self, from: Data(buffer: response.body))
                #expect(reply.checked == 0)
                #expect(reply.unchecked == 3)
                #expect(reply.damaged == 0)
                #expect(reply.degraded == 0)
                // 2026-08-08 smoke フィードバック: 未検査でもキー自体は必ず送る（旧サーバとの
                // 判別材料になるため、値が nil でも省略してはいけない ―― DTOs.swift 参照）。
                #expect(reply.lastScanAtKnown == true)
                #expect(reply.lastScanAt == nil, "一度も検査していないので最終検査時刻は無いはず")
            }
        }
    }

    @Test("scan は候補を走査して内訳を返し、結果が summary に残る")
    func scanPersistsResults() async throws {
        let fixture = try TestLibraryFixture(name: "IntegScan", bookCount: 2)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/scan",
                method: .post,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                let reply = try JSONDecoder().decode(
                    IntegrityScanReply.self, from: Data(buffer: response.body))
                // fixture の本が候補になるかは fixture 側の pages 設定に依存するため件数は固定しない。
                // 代わりに「内訳の合計＋永続化失敗＝走査数」という常に成り立つべき不変条件を検証する
                // （persistenceFailures に落ちた本は byStatus に計上されないため、これを足さないと
                // fixture 側で永続化失敗が起きた場合に不変条件が崩れる）。
                #expect(reply.ok + reply.damaged + reply.empty + reply.missing
                        + reply.unsupported + reply.persistenceFailures == reply.scanned,
                        "内訳の合計＋永続化失敗が走査数と一致しない")
            }
            // 2 回目の summary は再スキャンなしで前回結果を返す（永続化の確認）。
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/summary",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let reply = try JSONDecoder().decode(
                    IntegritySummaryReply.self, from: Data(buffer: response.body))
                #expect(reply.checked > 0, "スキャン結果が永続化されていない")
                // 2026-08-08 smoke フィードバック: スキャン後は最終検査時刻が入る
                // （`Database.integrityLastCheckedAt()` の MAX(checked_at) 参照）。
                #expect(reply.lastScanAtKnown == true)
                #expect(reply.lastScanAt != nil, "スキャン後なので最終検査時刻が入っているはず")
            }
        }
    }

    @Test("list は status を絞って返す")
    func listFiltersByStatus() async throws {
        let fixture = try TestLibraryFixture(name: "IntegList", bookCount: 2)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/list?status=damaged",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let reply = try JSONDecoder().decode(
                    IntegrityListReply.self, from: Data(buffer: response.body))
                // items が空だと allSatisfy は自明に真になるため、それだけでは検証にならない。
                // 「damaged の件数が summary の damaged と一致する」ことを併せて見る。
                #expect(reply.items.allSatisfy { $0.status == "damaged" })
                try await client.execute(
                    uri: "/api/v1/libraries/\(lib.uuid)/integrity/summary",
                    method: .get,
                    headers: [.authorization: "Bearer R"]
                ) { summaryResponse in
                    let summary = try JSONDecoder().decode(
                        IntegritySummaryReply.self, from: Data(buffer: summaryResponse.body))
                    #expect(reply.items.count == summary.damaged,
                            "list の件数が summary の damaged と食い違う")
                }
            }
        }
    }

    @Test("未知の status は 400")
    func unknownStatusIsBadRequest() async throws {
        let fixture = try TestLibraryFixture(name: "IntegBadStatus", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/list?status=bogus",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("scan は書き込み権限が要る（読み取りトークンでは拒否）")
    func scanRequiresWriteToken() async throws {
        let fixture = try TestLibraryFixture(name: "IntegAuth", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/integrity/scan",
                method: .post,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status != .ok, "読み取りトークンでスキャンが通ってしまう")
            }
        }
    }
}
