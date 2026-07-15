// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// general-settings（GET/PUT）: G12b-3a 一般タブ設定（ライブラリ名＋バックアップ設定）。
@Suite("general-settings endpoint (G12b-3a)", .serialized)
struct GeneralSettingsEndpointTests {

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// GET: DB にシードした display_name/backup_enabled/backup_generations を DTO に反映する（R 可）。
    @Test func getReturnsSettingsFromDB() async throws {
        let fixture = try TestLibraryFixture(name: "GSGet", bookCount: 0)
        defer { fixture.cleanup() }
        try fixture.db.setLibrarySetting(key: "display_name", value: "Lib")
        try fixture.db.setLibrarySetting(key: "backup_enabled", value: "true")
        try fixture.db.setLibrarySetting(key: "backup_generations", value: "7")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/general-settings",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(GeneralSettingsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.displayName == "Lib")
                #expect(dto.backupEnabled == true)
                #expect(dto.backupGenerations == 7)
            }
        }
    }

    /// PUT: edit トークンは 403、admin トークンは 2xx で永続化 → 続く GET に反映。
    @Test func putPersistsAndRequiresAdmin() async throws {
        let body = try JSONEncoder().encode(GeneralSettingsDTO(displayName: "New", backupEnabled: false, backupGenerations: 3))

        // edit トークン（adminTier: false, Bearer W）→ 403
        let editFixture = try TestLibraryFixture(name: "GSPutEdit", bookCount: 0)
        defer { editFixture.cleanup() }
        let editLib = editFixture.servedLibrary()
        let editApp = makeApp(fixture: editFixture, adminTier: false)
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(editLib.uuid)/general-settings",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .forbidden) }
        }

        // admin トークン（adminTier: true, Bearer W）→ 2xx、続く GET で永続化を確認
        let adminFixture = try TestLibraryFixture(name: "GSPutAdmin", bookCount: 0)
        defer { adminFixture.cleanup() }
        let adminLib = adminFixture.servedLibrary()
        let adminApp = makeApp(fixture: adminFixture, adminTier: true)
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/general-settings",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .ok) }
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/general-settings",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                let dto = try JSONDecoder().decode(GeneralSettingsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.displayName == "New")
                #expect(dto.backupEnabled == false)
                #expect(dto.backupGenerations == 3)
            }
        }
    }
}
