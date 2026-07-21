// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

@Suite("GET/PUT /watch-config endpoint")
struct WatchConfigEndpointTests {

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false,
                          onScanNowRequested: (@Sendable (String) -> Void)? = nil) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier,
                          onScanNowRequested: onScanNowRequested),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// GET on empty lib returns enabled=false, folders=[].
    @Test func getDefaultReturnsDisabledEmpty() async throws {
        let fixture = try TestLibraryFixture(name: "WCDefault", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.enabled == false)
                #expect(dto.folders.isEmpty)
            }
        }
    }

    /// PUT → GET roundtrip: enabled=true + one folder.
    @Test func putThenGetRoundtrip() async throws {
        let fixture = try TestLibraryFixture(name: "WCRoundtrip", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        // G12b-2c: 新規 folder id はパス検証（実在＋ディレクトリ）が入るため実ディレクトリを使う。
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let folder = WatchedFolderDTO(id: "abc", path: tmpDir.path, enabled: true)
        let putBody = WatchConfigDTO(enabled: true, folders: [folder])
        let bodyData = try JSONEncoder().encode(putBody)
        try await app.test(.router) { client in
            // PUT
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            // GET
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.enabled == true)
                #expect(dto.folders.count == 1)
                #expect(dto.folders[0].path == tmpDir.path)
            }
        }
    }

    /// PUT with read token → 403.
    @Test func putWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "WCForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let bodyData = try JSONEncoder().encode(WatchConfigDTO(enabled: false, folders: []))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// G12b-3a: PUT は admin 専用 — edit トークンでは 403、admin トークンでは 2xx。
    @Test func putWatchConfigRequiresAdmin() async throws {
        let bodyData = try JSONEncoder().encode(WatchConfigDTO(enabled: false, folders: []))

        // edit トークン（adminTier: false, Bearer W）→ 403
        let editFixture = try TestLibraryFixture(name: "WCAdminTierEdit", bookCount: 0)
        defer { editFixture.cleanup() }
        let editLib = editFixture.servedLibrary()
        let editApp = makeApp(fixture: editFixture, adminTier: false)
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(editLib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }

        // admin トークン（adminTier: true, Bearer W）→ 2xx
        let adminFixture = try TestLibraryFixture(name: "WCAdminTierAdmin", bookCount: 0)
        defer { adminFixture.cleanup() }
        let adminLib = adminFixture.servedLibrary()
        let adminApp = makeApp(fixture: adminFixture, adminTier: true)
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(adminLib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// G12b-2c: GET が folders[].subfolderMode（recurse）と presets（命名プリセット一覧）を返す。
    @Test func getReturnsSubfolderModeAndPresets() async throws {
        let fixture = try TestLibraryFixture(name: "WCSubfolderPresets", bookCount: 0)
        defer { fixture.cleanup() }
        // 準備: 庫に watched_folders(1件・subfolderMode=recurse) と filename_format_presets(1件) を設定
        let folders = [WatchedFolder(id: "f1", path: "/tmp/watch1", enabled: true, subfolderMode: .recurse)]
        let foldersData = try JSONEncoder().encode(folders)
        try fixture.db.setLibrarySetting(key: "watched_folders", value: String(decoding: foldersData, as: UTF8.self))
        let presets = [FilenameFormatPreset(id: "p1", name: "既定プリセット", format: "@title")]
        let presetsData = try JSONEncoder().encode(presets)
        try fixture.db.setLibrarySetting(key: "filename_format_presets", value: String(decoding: presetsData, as: UTF8.self))

        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        // 実行: GET /libraries/:lib/watch-config（R トークン可）
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                // 検証:
                #expect(dto.folders.first?.subfolderMode == .recurse)
                #expect(dto.presets?.contains { $0.id == "p1" && $0.name == "既定プリセット" } == true)
            }
        }
    }

    /// G12b-2c: PUT は id マージ — 既存 folder id の baseline はサーバ保持（クライアント送信値を無視）。
    @Test func putPreservesBaselineForExistingFolder() async throws {
        let fixture = try TestLibraryFixture(name: "WCPreserveBaseline", bookCount: 0)
        defer { fixture.cleanup() }
        // 準備: 既存 folder id=f1 に baseline=["/x/a.zip"] を保管
        let existing = [WatchedFolder(id: "f1", path: "/tmp/wc-f1", enabled: true, baseline: ["/x/a.zip"])]
        let existingData = try JSONEncoder().encode(existing)
        try fixture.db.setLibrarySetting(key: "watched_folders", value: String(decoding: existingData, as: UTF8.self))
        try fixture.db.setLibrarySetting(key: "folder_watch_enabled", value: "true")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            // 実行: PUT で f1 の enabled を false に（baseline は空で送る）
            let folder = WatchedFolderDTO(id: "f1", path: "/tmp/wc-f1", enabled: false, baseline: [])
            let putBody = WatchConfigDTO(enabled: true, folders: [folder])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            // 検証: 保管後 GET の f1.baseline == ["/x/a.zip"]（サーバが保持）、enabled == false
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.folders.count == 1)
                #expect(dto.folders.first?.baseline == ["/x/a.zip"])
                #expect(dto.folders.first?.enabled == false)
            }
        }
    }

    /// G12b-2c: PUT は新規 folder id のパスを検証する（実在しない/ディレクトリでない → 400）。
    @Test func putRejectsNewFolderWithInvalidPath() async throws {
        let fixture = try TestLibraryFixture(name: "WCInvalidPath", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            // 実行: PUT で新規 id=f2, path="/no/such/dir" を送る
            let folder = WatchedFolderDTO(id: "f2", path: "/no/such/dir", enabled: true)
            let putBody = WatchConfigDTO(enabled: true, folders: [folder])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                // 検証: HTTP 400（存在しない/ディレクトリでない）＋ body の JSON に不正パスを含む
                // （A3: クライアントがどのパスが不正か提示できるようにするため。Hummingbird は
                // `{"error":{"message":"..."}}` で message を返す＝クライアントが JSON デコードで復元する）。
                #expect(response.status == .badRequest)
                struct HBError: Decodable { struct E: Decodable { let message: String }; let error: E }
                let parsed = try JSONDecoder().decode(HBError.self, from: Data(buffer: response.body))
                #expect(parsed.error.message.contains("/no/such/dir"))
            }
        }
    }

    /// G12b-2c: PUT は新規 folder id のパス検証で「実在するがディレクトリでない（ファイル）」も 400 にする。
    @Test func putRejectsNewFolderWithFilePathNotDirectory() async throws {
        let fixture = try TestLibraryFixture(name: "WCFileNotDir", bookCount: 0)
        defer { fixture.cleanup() }
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-notadir-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: filePath)
        defer { try? FileManager.default.removeItem(at: filePath) }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            let folder = WatchedFolderDTO(id: "f2b", path: filePath.path, enabled: true)
            let putBody = WatchConfigDTO(enabled: true, folders: [folder])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// G12b-2c: PUT は新規 folder id の baseline を現在の中身でスキャンする（既存スキップ）。
    @Test func putScansBaselineForNewValidFolder() async throws {
        let fixture = try TestLibraryFixture(name: "WCScanBaseline", bookCount: 0)
        defer { fixture.cleanup() }
        // 準備: 一時ディレクトリに既存ファイル 1 個
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let existingFile = tmpDir.appendingPathComponent("existing.zip")
        try Data("dummy".utf8).write(to: existingFile)
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            // 実行: PUT で新規 id=f3, path=一時dir, subfolderMode=topLevelOnly を送る（baseline 空）
            let folder = WatchedFolderDTO(id: "f3", path: tmpDir.path, enabled: true,
                                          baseline: [], subfolderMode: .topLevelOnly)
            let putBody = WatchConfigDTO(enabled: true, folders: [folder])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            // 検証: 保管後 GET の f3.baseline が既存ファイルを含む（既存スキップ）
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                // macOS では /tmp が /private/var/... のシンボリックリンクのため、
                // contentsOfDirectory が返す絶対パスの先頭が変わりうる（既存の WatchFolderScannerRecurseTests と同様、
                // ファイル名一致で判定する）。
                #expect(dto.folders.first?.baseline.contains { $0.hasSuffix("/existing.zip") } == true)
            }
        }
    }

    /// G9b Task3: PUT で subfolderMode=archive を送ると、DTO→WatchedFolder ブリッジ経由で
    /// 保存され、GET で archive のまま返る（デコード時にサイレントに他モードへ落ちないことの回帰）。
    @Test func putArchiveModeRoundTripsThroughBridge() async throws {
        let fixture = try TestLibraryFixture(name: "WCArchiveMode", bookCount: 0)
        defer { fixture.cleanup() }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            let folder = WatchedFolderDTO(id: "f4", path: tmpDir.path, enabled: true,
                                          baseline: [], subfolderMode: .archive)
            let putBody = WatchConfigDTO(enabled: true, folders: [folder])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.folders.first?.subfolderMode == .archive)
            }
        }
    }

    /// G12b-2c: PUT で DTO に含まれない既存 folder id は削除される。
    @Test func putDeletesMissingFolder() async throws {
        let fixture = try TestLibraryFixture(name: "WCDeleteMissing", bookCount: 0)
        defer { fixture.cleanup() }
        // 準備: 既存 f1
        let existing = [WatchedFolder(id: "f1", path: "/tmp/wc-del-f1", enabled: true)]
        let existingData = try JSONEncoder().encode(existing)
        try fixture.db.setLibrarySetting(key: "watched_folders", value: String(decoding: existingData, as: UTF8.self))
        try fixture.db.setLibrarySetting(key: "folder_watch_enabled", value: "true")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            // 実行: PUT で folders=[]（f1 を含めない）
            let putBody = WatchConfigDTO(enabled: true, folders: [])
            let bodyData = try JSONEncoder().encode(putBody)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            // 検証: 保管後 GET の folders が空
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.folders.isEmpty)
            }
        }
    }

    /// G12b-3c: POST watch/import-existing は admin 専用（edit トークン → 403）で、
    /// 対象 folder の baseline をクリアして scan を発火する。他 folder の baseline は不変。
    @Test func importExistingClearsBaselineAndRequiresAdmin() async throws {
        let fixture = try TestLibraryFixture(name: "IEEdit", bookCount: 0)
        defer { fixture.cleanup() }
        // 準備: watched_folders に baseline 付きフォルダを2件シード（対象外 folder は不変を検証するため）
        let existing = [
            WatchedFolder(id: "F1", path: "/tmp/ie-f1", enabled: true, baseline: ["/tmp/ie-f1/a.zip", "/tmp/ie-f1/b.zip"]),
            WatchedFolder(id: "F2", path: "/tmp/ie-f2", enabled: true, baseline: ["/tmp/ie-f2/c.zip"])
        ]
        let existingData = try JSONEncoder().encode(existing)
        try fixture.db.setLibrarySetting(key: "watched_folders", value: String(decoding: existingData, as: UTF8.self))
        try fixture.db.setLibrarySetting(key: "folder_watch_enabled", value: "true")
        let lib = fixture.servedLibrary()
        let body = try JSONEncoder().encode(ImportExistingRequest(folderID: "F1"))

        // edit トークン（adminTier: false, Bearer W）→ 403、callback 未呼出
        nonisolated(unsafe) var editCalledUUID: String?
        let editApp = makeApp(fixture: fixture, adminTier: false, onScanNowRequested: { uuid in
            editCalledUUID = uuid
        })
        try await editApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch/import-existing",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(editCalledUUID == nil)

        // admin トークン（adminTier: true, Bearer W）・存在する folderID → 2xx かつ F1.baseline が空に、F2 は不変、
        // かつ onScanNowRequested コールバックが当該 lib.uuid で呼ばれる（G12b-3a と同じ scan 発火経路）。
        nonisolated(unsafe) var adminCalledUUID: String?
        let adminApp = makeApp(fixture: fixture, adminTier: true, onScanNowRequested: { uuid in
            adminCalledUUID = uuid
        })
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch/import-existing",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.folders.first { $0.id == "F1" }?.baseline == [])
                #expect(dto.folders.first { $0.id == "F2" }?.baseline == ["/tmp/ie-f2/c.zip"])
            }
        }
        #expect(adminCalledUUID == lib.uuid)

        // 存在しない folderID → 404
        let notFoundBody = try JSONEncoder().encode(ImportExistingRequest(folderID: "NOPE"))
        try await adminApp.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch/import-existing",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(notFoundBody))
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
