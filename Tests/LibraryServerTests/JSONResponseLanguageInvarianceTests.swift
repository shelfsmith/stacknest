// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// G55 最終レビュー item 1: API の JSON（= CLI の `--json` と MCP が受け取るもの）は
/// `Accept-Language` で値が変わらない。保存値（種まきの既定名「既定」・既定グラント名・
/// お気に入り棚の名前）は訳さずそのまま返し、表示用の訳はクライアント側が行う。
/// 実エンドポイントに ja と en のヘッダで同じ要求を投げ、デコードした JSON が一致することを確かめる。
@Suite("API JSON is identical for Accept-Language ja/en (G55)")
struct JSONResponseLanguageInvarianceTests {
    private static let adminToken = "ADM"

    private func makeFixture() throws -> TestLibraryFixture {
        let fixture = try TestLibraryFixture(name: "L10N-INV", bookCount: 1)
        let presets = [
            FilenameFormatPreset(id: "p-seed", name: FilenameFormatPreset.seededDefaultName, format: "@title"),
            FilenameFormatPreset(id: "p-blank", name: "  ", format: "@author @title"),
            FilenameFormatPreset(id: "p-user", name: "自分用", format: "@series"),
        ]
        let json = String(decoding: try JSONEncoder().encode(presets), as: UTF8.self)
        try fixture.db.setLibrarySetting(key: "filename_format_presets", value: json)
        return fixture
    }

    private func makeApp(_ lib: ServedLibrary) -> some ApplicationProtocol {
        let grants = [
            Grant(id: "g-admin", label: "(既定) 編集", token: Self.adminToken, tier: .admin, scope: .all,
                  createdAt: Date(timeIntervalSince1970: 0)),
            Grant(id: "g-read", label: "(既定) 閲覧", token: "RD", tier: .read, scope: .all,
                  createdAt: Date(timeIntervalSince1970: 0)),
        ]
        return LibraryServerCore(
            config: .init(port: 0, token: "u", editToken: nil, adminTier: true, grantsProvider: { grants }),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// 同じ GET を ja と en で投げ、JSON をデコードした値（キー順に依存しない）を返す。
    private func fetch(_ client: some TestClientProtocol, _ uri: String, lang: String) async throws -> NSObject {
        try await client.execute(
            uri: uri, method: .get,
            headers: [.authorization: "Bearer \(Self.adminToken)", .acceptLanguage: lang]
        ) { res in
            #expect(res.status == .ok, "\(uri) [\(lang)] → \(res.status)")
            return try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as! NSObject
        }
    }

    @Test("watch-config / presets / shelves / grants の JSON は ja と en で同一", arguments: [
        "watch-config", "presets", "shelves", "grants",
    ])
    func responsesAreLanguageInvariant(endpoint: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let uri = endpoint == "grants" ? "/api/v1/grants" : "/api/v1/libraries/\(lib.uuid)/\(endpoint)"
        try await makeApp(lib).test(.router) { client in
            let ja = try await fetch(client, uri, lang: "ja")
            let en = try await fetch(client, uri, lang: "en")
            #expect(ja.isEqual(en), "\(endpoint): ja=\(ja) en=\(en)")
        }
    }

    /// watch-config のプリセット名は保存値そのもの（空白だけの名前は従来どおり format で代替）。
    @Test("watch-config のプリセット名は en でも保存値のまま")
    func watchConfigPresetNamesAreStoredValues() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        try await makeApp(lib).test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config", method: .get,
                headers: [.authorization: "Bearer \(Self.adminToken)", .acceptLanguage: "en"]
            ) { res in
                #expect(res.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: res.body))
                let names = Dictionary(uniqueKeysWithValues: (dto.presets ?? []).map { ($0.id, $0.name) })
                #expect(names == ["p-seed": "既定", "p-blank": "@author @title", "p-user": "自分用"])
            }
        }
    }
}
