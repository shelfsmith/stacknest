// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// integrity-check（GET）・backup-now（POST）: G12b-3a 保守エンドポイント（いずれも admin）。
@Suite("maintenance endpoints (G12b-3a)", .serialized)
struct MaintenanceEndpointTests {

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// GET /integrity-check: 新規 DB は healthy==true, rows==["ok"]。edit トークンは 403。
    @Test func integrityCheckReturnsHealthyForFreshDB() async throws {
        // edit トークン（adminTier: false, Bearer W）→ 403
        let editFixture = try TestLibraryFixture(name: "ICEdit", bookCount: 0)
        defer { editFixture.cleanup() }
        let editLib = editFixture.servedLibrary()
        let editApp = makeApp(fixture: editFixture, adminTier: false)
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(editLib.uuid)/integrity-check",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }

        // admin トークン（adminTier: true, Bearer W）→ 200, healthy==true, rows==["ok"]
        let adminFixture = try TestLibraryFixture(name: "ICAdmin", bookCount: 0)
        defer { adminFixture.cleanup() }
        let adminLib = adminFixture.servedLibrary()
        let adminApp = makeApp(fixture: adminFixture, adminTier: true)
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/integrity-check",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(IntegrityCheckDTO.self, from: Data(buffer: resp.body))
                #expect(dto.healthy == true)
                #expect(dto.rows == ["ok"])
            }
        }
    }

    /// POST /backup-now: バックアップファイルが増える。edit トークンは 403。
    @Test func backupNowCreatesBackupFile() async throws {
        // edit トークン（adminTier: false, Bearer W）→ 403
        let editFixture = try TestLibraryFixture(name: "BNEdit", bookCount: 0)
        defer { editFixture.cleanup() }
        let editLib = editFixture.servedLibrary()
        let editApp = makeApp(fixture: editFixture, adminTier: false)
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(editLib.uuid)/backup-now",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }

        // admin トークン（adminTier: true, Bearer W）→ 2xx、Backups/ 内のファイル数が増える
        let adminFixture = try TestLibraryFixture(name: "BNAdmin", bookCount: 0)
        defer { adminFixture.cleanup() }
        let adminLib = adminFixture.servedLibrary()
        let backupsDir = BackupManager.backupsDir(for: adminFixture.bundleURL)
        let before = BackupManager.list(in: backupsDir).count
        let adminApp = makeApp(fixture: adminFixture, adminTier: true)
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/backup-now",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .noContent) }
        }
        let after = BackupManager.list(in: backupsDir).count
        #expect(after > before)
    }
}
