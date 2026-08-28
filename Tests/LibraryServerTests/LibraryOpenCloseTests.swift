// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// POST /local/libraries/open, /local/libraries/close（G27b Task7）。
///
/// `openLibrary`/`closeLibrary` は App 層（LocalControlController）が openWindow/AppState.activeInstances
/// を使って実装するため、ここでは fake クロージャを注入してルーティング・認証・セキュリティ境界だけを
/// 検証する（実 NSWindow は App-target テストでも作れない・CLAUDE.md の絶対制約）。
///
/// **最重要**: `enableLocalLibraryControl` が false（ServerController=共有サーバの既定）だと
/// ルート自体が存在せず 404 になること。これがルート・スコーピングの唯一のゲートであり、
/// 将来の tier 昇格バグがあっても共有サーバにこの API が出ないことをここで固定する。
@Suite("POST /local/libraries/open,close (G27b Task7)", .serialized)
struct LibraryOpenCloseTests {

    private func makeCore(
        enableLocalLibraryControl: Bool,
        adminTier: Bool = true,
        openLibrary: (@Sendable (URL) async throws -> String)? = nil,
        closeLibrary: (@Sendable (String) async throws -> Void)? = nil,
        renameFiles: (@Sendable (String, RenameFilesRequest) async -> RenameFilesReply?)? = nil
    ) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(
                port: 0, token: "R", editToken: "W", adminTier: adminTier,
                enableLocalLibraryControl: enableLocalLibraryControl,
                openLibrary: openLibrary, closeLibrary: closeLibrary,
                renameFiles: renameFiles),
            dataSource: StaticLibraryDataSource(libraries: [])
        )
    }

    // MARK: - 1) セキュリティ境界: 共有サーバ相当（フラグ false）にはルートが存在しない

    @Test func sharedServerDoesNotExposeOpenRoute() async throws {
        // フラグを立てず、closure も渡さない ＝ ServerController が実際に組む config と同じ形。
        let core = makeCore(enableLocalLibraryControl: false)
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(OpenLibraryRequest(path: "/tmp/whatever"))
            try await client.execute(
                uri: "/local/libraries/open", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .notFound)
            }
        }
    }

    @Test func sharedServerDoesNotExposeCloseRoute() async throws {
        let core = makeCore(enableLocalLibraryControl: false)
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(CloseLibraryRequest(uuid: "some-uuid"))
            try await client.execute(
                uri: "/local/libraries/close", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .notFound)
            }
        }
    }

    /// フラグが true でも openLibrary/closeLibrary 未注入（設定ミス）なら 501 で落ち着く
    /// （クラッシュ・ハングしない）ことも併せて確認する。
    @Test func enabledWithoutClosuresReturnsNotImplemented() async throws {
        let core = makeCore(enableLocalLibraryControl: true)
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(OpenLibraryRequest(path: "/tmp/whatever"))
            try await client.execute(
                uri: "/local/libraries/open", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .notImplemented)
            }
        }
    }

    // MARK: - 2) ローカル制御では開閉できる

    @Test func localControlCanOpenAndClose() async throws {
        let closedUUIDs = ClosedUUIDBox()
        let core = makeCore(
            enableLocalLibraryControl: true,
            openLibrary: { url in "uuid-for-\(url.lastPathComponent)" },
            closeLibrary: { uuid in await closedUUIDs.add(uuid) }
        )
        try await core.buildApplication().test(.router) { client in
            let openBody = try JSONEncoder().encode(OpenLibraryRequest(path: "/tmp/MyLib.stacknestlib"))
            try await client.execute(
                uri: "/local/libraries/open", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(openBody))
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try JSONDecoder().decode(OpenLibraryReply.self, from: Data(buffer: resp.body))
                #expect(reply.uuid == "uuid-for-MyLib.stacknestlib")
            }

            let closeBody = try JSONEncoder().encode(CloseLibraryRequest(uuid: "uuid-for-MyLib.stacknestlib"))
            try await client.execute(
                uri: "/local/libraries/close", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(closeBody))
            ) { resp in
                #expect(resp.status == .noContent)
            }
        }
        let closed = await closedUUIDs.values
        #expect(closed == ["uuid-for-MyLib.stacknestlib"])
    }

    /// 読み取り専用（admin tier 未満）トークンは拒否される（他の admin 専用ルートと同じ扱い・
    /// FullScanEndpointTests.readOnlyTokenCannotStart と同じ形で adminTier: false にして tier を分ける
    /// ―― 実運用の LocalControlController は adminTier: true で R/W いずれも admin 昇格するため、
    /// これは requireAdmin() ゲート自体の回帰防止テスト）。
    @Test func readOnlyTokenCannotOpen() async throws {
        let core = makeCore(
            enableLocalLibraryControl: true, adminTier: false,
            openLibrary: { _ in "should-not-be-called" }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(OpenLibraryRequest(path: "/tmp/x"))
            try await client.execute(
                uri: "/local/libraries/open", method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .forbidden)
            }
        }
    }

    // MARK: - 3) 既に開いている庫を open すると既存 UUID が返る（新規ウィンドウは開かない）

    /// 実装契約のテスト: App 層（LocalControlController）の openLibrary クロージャは、
    /// 「同じパスを 2 回 open されたら、2 回目は新規ウィンドウを開かずに 1 回目と同じ UUID を返す」
    /// という契約を満たさなければならない。ここでは実 NSWindow/AppState は使えないため、
    /// その契約どおりに振る舞う fake（パス→UUID の辞書で重複 open を検知する）を使い、
    /// ルートが「2 回目の呼び出しでも openLibrary が返した値をそのまま中継する」ことを確認する。
    @Test func openingAlreadyOpenLibraryReturnsExistingUUIDWithoutReopening() async throws {
        let registry = FakeAlreadyOpenRegistry()
        let core = makeCore(
            enableLocalLibraryControl: true,
            openLibrary: { url in await registry.open(path: url.path) }
        )
        try await core.buildApplication().test(.router) { client in
            func open() async throws -> OpenLibraryReply {
                let body = try JSONEncoder().encode(OpenLibraryRequest(path: "/tmp/SameLib.stacknestlib"))
                var reply: OpenLibraryReply?
                try await client.execute(
                    uri: "/local/libraries/open", method: .post,
                    headers: [.authorization: "Bearer W", .contentType: "application/json"],
                    body: .init(bytes: Array(body))
                ) { resp in
                    #expect(resp.status == .ok)
                    reply = try JSONDecoder().decode(OpenLibraryReply.self, from: Data(buffer: resp.body))
                }
                return try #require(reply)
            }
            let first = try await open()
            let second = try await open()
            #expect(first.uuid == second.uuid)
        }
        let opens = await registry.openCallCount
        #expect(opens == 1, "2 回目は新規オープンとしてカウントされてはならない")
    }

    // MARK: - 4) 存在しない/非対応パスはクリーンに失敗する

    @Test func badPathFailsCleanly() async throws {
        let core = makeCore(
            enableLocalLibraryControl: true,
            openLibrary: { url in throw LocalLibraryControlError.invalidPath(url.path) }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(OpenLibraryRequest(path: "/no/such/path"))
            try await client.execute(
                uri: "/local/libraries/open", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .badRequest)
            }
        }
    }

    @Test func closingUnknownUUIDReturnsNotFound() async throws {
        let core = makeCore(
            enableLocalLibraryControl: true,
            closeLibrary: { _ in throw LocalLibraryControlError.notFound }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(CloseLibraryRequest(uuid: "unknown"))
            try await client.execute(
                uri: "/local/libraries/close", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .notFound)
            }
        }
    }

    // MARK: - 5) G47: rename-files のセキュリティ境界・入力検証

    /// 共有サーバ相当（フラグ false）では rename-files ルートも存在しない。
    /// open/close と同じ「ローカル制御専用」を守る唯一の構造的な保険。
    @Test func sharedServerDoesNotExposeRenameFilesRoute() async throws {
        let calls = RenameFilesCallBox()
        let core = makeCore(
            enableLocalLibraryControl: false,
            renameFiles: { uuid, body in await calls.record(uuid, body); return RenameFilesReply(status: "ok") }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(RenameFilesRequest(ids: [1]))
            try await client.execute(
                uri: "/local/libraries/some-uuid/rename-files", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .notFound)
            }
        }
        let count = await calls.count
        #expect(count == 0, "ルートに到達していない証拠として closure は一度も呼ばれない")
    }

    /// 読み取り専用（admin tier 未満）トークンは拒否される（他の admin 専用ルートと同じ扱い）。
    @Test func readOnlyTokenCannotRenameFiles() async throws {
        let calls = RenameFilesCallBox()
        let core = makeCore(
            enableLocalLibraryControl: true, adminTier: false,
            renameFiles: { uuid, body in await calls.record(uuid, body); return RenameFilesReply(status: "ok") }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(RenameFilesRequest(ids: [1]))
            try await client.execute(
                uri: "/local/libraries/some-uuid/rename-files", method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .forbidden)
            }
        }
        let count = await calls.count
        #expect(count == 0, "ルートに到達していない証拠として closure は一度も呼ばれない")
    }

    /// `presetID` と `format` を同時に指定したら 400（片方を黙って無視すると
    /// 「指定したはずの書式と違う名前が付いた」に化ける）。
    @Test func renameFilesRejectsPresetIDAndFormatTogether() async throws {
        let calls = RenameFilesCallBox()
        let core = makeCore(
            enableLocalLibraryControl: true,
            renameFiles: { uuid, body in await calls.record(uuid, body); return RenameFilesReply(status: "ok") }
        )
        try await core.buildApplication().test(.router) { client in
            let body = try JSONEncoder().encode(
                RenameFilesRequest(ids: [1], presetID: "preset-a", format: "@title"))
            try await client.execute(
                uri: "/local/libraries/some-uuid/rename-files", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in
                #expect(resp.status == .badRequest)
            }
        }
        let count = await calls.count
        #expect(count == 0, "presetID/format の同時指定はルート到達前に弾かれる")
    }
}

/// close() の呼び出しを記録する actor（テスト用フェイク）。
private actor ClosedUUIDBox {
    private(set) var values: [String] = []
    func add(_ uuid: String) { values.append(uuid) }
}

/// 「同じパスを 2 回 open したら 2 回目は既存 UUID を返す」契約を再現する fake registry。
/// 実装（LocalControlController.openLibrary）は AppState.activeInstances を使って同じ契約を守る。
private actor FakeAlreadyOpenRegistry {
    private var openPathsToUUID: [String: String] = [:]
    private(set) var openCallCount = 0

    func open(path: String) -> String {
        if let existing = openPathsToUUID[path] { return existing }
        openCallCount += 1
        let uuid = "uuid-\(openCallCount)"
        openPathsToUUID[path] = uuid
        return uuid
    }
}

/// renameFiles closure の呼び出しを記録する actor（テスト用フェイク）。
/// 404/403/400 のケースでこれが一度も呼ばれないことが「ルートに到達していない」証拠になる。
private actor RenameFilesCallBox {
    private(set) var count = 0
    func record(_ uuid: String, _ body: RenameFilesRequest) {
        count += 1
    }
}
