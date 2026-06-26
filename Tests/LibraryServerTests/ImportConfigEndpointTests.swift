// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// per-library import-config（GET/PUT）＋ global import-config（GET/PUT）。
/// global は UserDefaults.standard を mutate するため `.serialized` で直列化し、
/// 各テストの末尾で元値へ復元する。
@Suite("import-config endpoint", .serialized)
struct ImportConfigEndpointTests {

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    // MARK: - per-library

    /// 未設定なら autoClassifyEnabled=nil / thickBookThreshold=nil。
    @Test func perLibraryGetDefaultIsNil() async throws {
        let fixture = try TestLibraryFixture(name: "ICLibDefault", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(ImportConfigDTO.self, from: Data(buffer: resp.body))
                #expect(dto.autoClassifyEnabled == nil)
                #expect(dto.thickBookThreshold == nil)
            }
        }
    }

    /// PUT(false/50) → GET 反映。
    @Test func perLibraryPutThenGetRoundtrip() async throws {
        let fixture = try TestLibraryFixture(name: "ICLibRound", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(ImportConfigDTO(autoClassifyEnabled: false, thickBookThreshold: 50))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .ok) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                let dto = try JSONDecoder().decode(ImportConfigDTO.self, from: Data(buffer: resp.body))
                #expect(dto.autoClassifyEnabled == false)
                #expect(dto.thickBookThreshold == 50)
            }
        }
    }

    /// PUT(nil/nil) で override 削除 → GET が nil に戻る。
    @Test func perLibraryPutNilClearsOverride() async throws {
        let fixture = try TestLibraryFixture(name: "ICLibClear", bookCount: 0)
        defer { fixture.cleanup() }
        // 事前に override を入れておく。
        try fixture.db.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: "false")
        try fixture.db.setLibrarySetting(key: ImportDefaults.libThickThresholdKey, value: "42")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(ImportConfigDTO(autoClassifyEnabled: nil, thickBookThreshold: nil))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .ok) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                let dto = try JSONDecoder().decode(ImportConfigDTO.self, from: Data(buffer: resp.body))
                #expect(dto.autoClassifyEnabled == nil)
                #expect(dto.thickBookThreshold == nil)
            }
        }
    }

    /// PUT は RW 専用：R は 403。
    @Test func perLibraryPutRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "ICLibForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(ImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: nil))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/import-config",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    // MARK: - global

    /// global PUT(35) → GET で 35。末尾で元値へ復元。
    @Test func globalPutThenGetRoundtrip() async throws {
        let savedAC = ImportDefaults.globalAutoClassify()
        let savedTH = ImportDefaults.globalThickThreshold()
        defer {
            ImportDefaults.setGlobalAutoClassify(savedAC)
            ImportDefaults.setGlobalThickThreshold(savedTH)
        }
        let fixture = try TestLibraryFixture(name: "ICGlobal", bookCount: 0)
        defer { fixture.cleanup() }
        let app = makeApp(fixture: fixture, adminTier: true)
        let body = try JSONEncoder().encode(GlobalImportConfigDTO(autoClassifyEnabled: false, thickBookThreshold: 35))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/import-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(GlobalImportConfigDTO.self, from: Data(buffer: resp.body))
                #expect(dto.autoClassifyEnabled == false)
                #expect(dto.thickBookThreshold == 35)
            }
            try await client.execute(
                uri: "/api/v1/import-config",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                let dto = try JSONDecoder().decode(GlobalImportConfigDTO.self, from: Data(buffer: resp.body))
                #expect(dto.autoClassifyEnabled == false)
                #expect(dto.thickBookThreshold == 35)
            }
        }
    }

    /// global PUT は RW 専用：R は 403。
    @Test func globalPutRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "ICGlobalForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(GlobalImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 20))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/import-config",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    // MARK: - add 解決（per-library override ?? global）

    /// per-library override を設定した状態で add しても本が追加できる
    /// （add ハンドラが override 読み取り経路を通っても壊れないことの確認）。
    @Test func addUsesPerLibraryOverride() async throws {
        let fixture = try TestLibraryFixture(name: "ICAddOverride", bookCount: 0)
        defer { fixture.cleanup() }
        // autoClassify=false を per-library override として設定。
        try fixture.db.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: "false")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        // 最小 PNG を一時ファイルに書く。
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ic-add-\(UUID().uuidString).png")
        try Data(base64Encoded: b64)!.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(AddBooksRequestDTO(paths: [pngURL.path]))
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try JSONDecoder().decode(AddBooksReplyDTO.self, from: Data(buffer: resp.body))
                #expect(reply.addedIDs.count == 1)
            }
        }
        // override=false（自動分類 OFF）が実際に解決へ反映されたことを検証:
        // BookImporter は autoClassify OFF 時、ファイルを未分類(bookType=0)で登録する。
        let books = try fixture.db.fetchAllBooks()
        #expect(books.count == 1)
        #expect(books.first?.bookType == 0)
    }
}
