// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

/// presets（GET/PUT）: G12b-3c 命名プリセット集合の取得＋更新。
@Suite("presets endpoint (G12b-3c)", .serialized)
struct PresetEndpointTests {
    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
                          dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])).buildApplication()
    }

    /// GET: DB にシードしたプリセット一覧＋既定 id を DTO に反映する（R 可）。
    @Test func getReturnsSeededPresets() async throws {
        let fx = try TestLibraryFixture(name: "PsGet", bookCount: 0); defer { fx.cleanup() }
        try fx.db.setLibrarySetting(key: "filename_format_presets",
            value: #"[{"id":"a","name":"A","format":"@title"},{"id":"b","name":"B","format":"[@author] @title"}]"#)
        try fx.db.setLibrarySetting(key: "filename_format_default_id", value: "b")
        let lib = fx.servedLibrary(); let app = makeApp(fixture: fx)
        try await app.test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(lib.uuid)/presets", method: .get,
                headers: [.authorization: "Bearer R"]) { r in
                #expect(r.status == .ok)
                let dto = try JSONDecoder().decode(PresetSetDTO.self, from: Data(buffer: r.body))
                #expect(dto.defaultID == "b"); #expect(dto.presets.count == 2)
                #expect(dto.presets.first { $0.id == "b" }?.format == "[@author] @title")
            }
        }
    }

    /// PUT: edit トークンは 403、admin トークンは 2xx で保存され、
    /// 無効な defaultID は validatedDefaultID により先頭プリセットへ矯正される。
    @Test func putRequiresAdminAndValidatesDefault() async throws {
        let body = try JSONEncoder().encode(PresetSetDTO(
            presets: [FilenameFormatPresetDTO(id: "x", name: "X", format: "@title")], defaultID: "nonexistent"))
        // edit → 403
        let fe = try TestLibraryFixture(name: "PsEdit", bookCount: 0); defer { fe.cleanup() }
        let le = fe.servedLibrary()
        try await makeApp(fixture: fe, adminTier: false).test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(le.uuid)/presets", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))) { r in #expect(r.status == .forbidden) }
        }
        // admin → 200・defaultID は先頭に矯正
        let fa = try TestLibraryFixture(name: "PsAdmin", bookCount: 0); defer { fa.cleanup() }
        let la = fa.servedLibrary()
        try await makeApp(fixture: fa, adminTier: true).test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(la.uuid)/presets", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))) { r in
                #expect(r.status == .ok)
                let dto = try JSONDecoder().decode(PresetSetDTO.self, from: Data(buffer: r.body))
                #expect(dto.defaultID == "x")   // validatedDefaultID で先頭へ
            }
        }
    }

    /// PUT: presets が空配列だと 400（サーバは最低 1 プリセットを要求する）。
    @Test func putRejectsEmpty() async throws {
        let body = try JSONEncoder().encode(PresetSetDTO(presets: [], defaultID: ""))
        let fa = try TestLibraryFixture(name: "PsEmpty", bookCount: 0); defer { fa.cleanup() }
        let la = fa.servedLibrary()
        try await makeApp(fixture: fa, adminTier: true).test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(la.uuid)/presets", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))) { r in #expect(r.status == .badRequest) }
        }
    }

    /// PUT: format が欠落（nil）または空白のみのプリセットが 1 件でもあると 400（Codex review）。
    /// 共有 DB キー filename_format_presets に "" が永続化され、ローカル側の読み取りも壊れるため。
    @Test func putRejectsMissingOrBlankFormat() async throws {
        let fa = try TestLibraryFixture(name: "PsBlankFormat", bookCount: 0); defer { fa.cleanup() }
        let la = fa.servedLibrary()
        let app = makeApp(fixture: fa, adminTier: true)

        // nil format
        let nilBody = try JSONEncoder().encode(PresetSetDTO(
            presets: [FilenameFormatPresetDTO(id: "x", name: "X", format: nil)], defaultID: "x"))
        try await app.test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(la.uuid)/presets", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(nilBody))) { r in #expect(r.status == .badRequest) }
        }

        // whitespace-only format
        let blankBody = try JSONEncoder().encode(PresetSetDTO(
            presets: [FilenameFormatPresetDTO(id: "x", name: "X", format: "   ")], defaultID: "x"))
        try await app.test(.router) { c in
            try await c.execute(uri: "/api/v1/libraries/\(la.uuid)/presets", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(blankBody))) { r in #expect(r.status == .badRequest) }
        }

        // 拒否後も DB には保存されていないこと（filename_format_presets が汚染されていない）。
        #expect(try fa.db.getLibrarySetting(key: "filename_format_presets") == nil)
    }
}
