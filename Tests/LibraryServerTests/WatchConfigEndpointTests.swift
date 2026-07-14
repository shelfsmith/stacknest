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
        let folder = WatchedFolderDTO(id: "abc", path: "/tmp/manga", enabled: true)
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
                #expect(dto.folders[0].path == "/tmp/manga")
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
}
