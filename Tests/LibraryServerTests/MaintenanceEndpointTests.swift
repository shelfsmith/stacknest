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

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false,
                          onScanNowRequested: (@Sendable (String) -> Void)? = nil) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier,
                          onScanNowRequested: onScanNowRequested),
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

    /// POST /watch/scan-now: admin → 204 かつ onScanNowRequested コールバックが当該 uuid で呼ばれる。
    /// edit トークンは 403 かつコールバック未呼出。
    @Test func scanNowRequiresAdminAndInvokesCallback() async throws {
        // edit トークン（adminTier: false, Bearer W）→ 403、callback 未呼出
        nonisolated(unsafe) var editCalledUUID: String?
        let editFixture = try TestLibraryFixture(name: "SNEdit", bookCount: 0)
        defer { editFixture.cleanup() }
        let editLib = editFixture.servedLibrary()
        let editApp = makeApp(fixture: editFixture, adminTier: false, onScanNowRequested: { uuid in
            editCalledUUID = uuid
        })
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(editLib.uuid)/watch/scan-now",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }
        #expect(editCalledUUID == nil)

        // admin トークン（adminTier: true, Bearer W）→ 204、callback が当該 uuid で呼ばれる
        nonisolated(unsafe) var adminCalledUUID: String?
        let adminFixture = try TestLibraryFixture(name: "SNAdmin", bookCount: 0)
        defer { adminFixture.cleanup() }
        let adminLib = adminFixture.servedLibrary()
        let adminApp = makeApp(fixture: adminFixture, adminTier: true, onScanNowRequested: { uuid in
            adminCalledUUID = uuid
        })
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/watch/scan-now",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .noContent) }
        }
        #expect(adminCalledUUID == adminLib.uuid)
    }

    // MARK: - G12b-3b: complete-metadata / compress-covers / cancel（admin・非同期ジョブ）

    /// POST /maintenance/complete-metadata: edit トークンは 403。
    @Test func completeMetadataRequiresAdmin() async throws {
        let fx = try TestLibraryFixture(name: "MtEdit", bookCount: 3)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: false)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/complete-metadata",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    /// POST /maintenance/complete-metadata: admin は 202（起動受理）。
    @Test func completeMetadataAcceptedForAdmin() async throws {
        let fx = try TestLibraryFixture(name: "MtAdmin", bookCount: 3)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: true)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/complete-metadata",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .accepted) }
        }
    }

    /// POST /maintenance/compress-covers: edit トークンは 403。
    @Test func compressCoversRequiresAdmin() async throws {
        let fx = try TestLibraryFixture(name: "CcEdit", bookCount: 3)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: false)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/compress-covers",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    /// POST /maintenance/compress-covers: admin は 202（起動受理）。
    @Test func compressCoversAcceptedForAdmin() async throws {
        let fx = try TestLibraryFixture(name: "CcAdmin", bookCount: 3)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: true)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/compress-covers",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .accepted) }
        }
    }

    /// POST /maintenance/cancel: edit トークンは 403。
    @Test func maintenanceCancelRequiresAdmin() async throws {
        let fx = try TestLibraryFixture(name: "MCEdit", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: false)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/cancel",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    /// POST /maintenance/cancel: admin は 204（実行中ジョブが無くても no-op で 204）。
    @Test func maintenanceCancelReturnsNoContentForAdmin() async throws {
        let fx = try TestLibraryFixture(name: "MCAdmin", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: true)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/cancel",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .noContent) }
        }
    }
}
