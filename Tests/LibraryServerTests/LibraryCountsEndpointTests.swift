// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import StackroomFormat
@testable import LibraryServer

/// G14: `GET /libraries/:lib/counts` — scope 非依存のライブラリ総数・最近件数。
@Suite("library counts endpoint")
struct LibraryCountsEndpointTests {

    private func makeApp(fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: false),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// 7 冊のうち 3 冊を最近日付（1 日前）、残り 4 冊を古い日付（30 日前）で登録。
    /// recent_days 未設定（既定 14 日）で libraryTotal=7 / recentCount=3 になること。
    @Test func countsReflectActualBooks() async throws {
        let fixture = try TestLibraryFixture(name: "CountsLib", bookCount: 0)
        defer { fixture.cleanup() }
        let now = Date()
        for i in 1...3 {
            try fixture.db.insertBook(BookRecord(
                id: i, title: "Recent \(i)",
                dateAdded: now.addingTimeInterval(-1 * 86400)
            ))
        }
        for i in 4...7 {
            try fixture.db.insertBook(BookRecord(
                id: i, title: "Old \(i)",
                dateAdded: now.addingTimeInterval(-30 * 86400)
            ))
        }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/counts",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(LibraryCountsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.libraryTotal == 7)
                #expect(dto.recentCount == 3)
                #expect(dto.recentDays == 14)
            }
        }
    }

    /// per-library `recent_days` override（例: 2 日）が反映されること。
    @Test func countsRespectRecentDaysOverride() async throws {
        let fixture = try TestLibraryFixture(name: "CountsLibOverride", bookCount: 0)
        defer { fixture.cleanup() }
        let now = Date()
        // 1 日前（2 日 override 内） / 5 日前（override 外）
        try fixture.db.insertBook(BookRecord(id: 1, title: "WithinOverride", dateAdded: now.addingTimeInterval(-1 * 86400)))
        try fixture.db.insertBook(BookRecord(id: 2, title: "OutsideOverride", dateAdded: now.addingTimeInterval(-5 * 86400)))
        try fixture.db.setLibrarySetting(key: "recent_days", value: "2")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/counts",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(LibraryCountsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.libraryTotal == 2)
                #expect(dto.recentCount == 1)
                #expect(dto.recentDays == 2)
            }
        }
    }

    /// 存在しないライブラリ UUID は 404。
    @Test func countsUnknownLibraryReturns404() async throws {
        let fixture = try TestLibraryFixture(name: "CountsLibMissing", bookCount: 0)
        defer { fixture.cleanup() }
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(UUID().uuidString)/counts",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .notFound)
            }
        }
    }
}
