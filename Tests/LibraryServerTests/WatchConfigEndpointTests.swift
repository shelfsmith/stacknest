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

    private func makeApp(fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
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
        let app = makeApp(fixture: fixture)
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
        let app = makeApp(fixture: fixture)
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
        let app = makeApp(fixture: fixture)
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
                // 検証: HTTP 400（存在しない/ディレクトリでない）
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
        let app = makeApp(fixture: fixture)
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
        let app = makeApp(fixture: fixture)
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
}
