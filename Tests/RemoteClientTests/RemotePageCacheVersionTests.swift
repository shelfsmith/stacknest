// SPDX-License-Identifier: MIT
// G4d 層2 (native): RemotePageCache のページキーに version（manifest.etag 由来）を持たせ、
// relink 直後にサーバの本体が差し替わっても旧版のページ画像を返さないようにする。
// RemoteCoverCache が表紙で既にやっている「version 差でキーが変わり再取得される／同版はヒットし
// 帯域を節約する」という契約を、page 用の RemotePageCache.Key にも同じ形で検証する
// （RemoteCoverCacheTests.swift の keyStringIncludesVersion / differentVersionMissesCacheAndRefetches
// と対の存在）。
import Testing
@testable import RemoteClient
import Foundation

@Suite("RemotePageCache page version key")
struct RemotePageCacheVersionTests {
    /// fetch クロージャは @Sendable なので captured var を直接 mutate できない。呼び出し回数は actor 経由。
    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rpcv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Step 1 (brief 記載のテスト): version 付き Key の string が版ごとに変わり、"|v<version>" を含む。
    @Test func pageKeyStringIncludesVersion() {
        let sid = UUID()
        let k1 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 1, kind: .page, page: 0, maxw: 1600, version: "v1")
        let k2 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 1, kind: .page, page: 0, maxw: 1600, version: "v2")
        #expect(k1.string != k2.string)
        #expect(k1.string.contains("|vv1"))
    }

    /// 真の判別テスト: 実物の RemotePageCache（一時ディレクトリ・実 actor）で、
    /// 同じ page に対して version が変われば必ずミス→再取得され（relink 後の stale page 防止）、
    /// version が同じなら必ずヒットし再取得されない（帯域節約の回帰防止）ことを検証する。
    /// RemoteCoverCacheTests.differentVersionMissesCacheAndRefetches と同型のアサーション。
    @Test func differentVersionMissesCacheButUnchangedVersionHits() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        let sid = UUID()
        let counter = Counter()
        let k1 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 7, kind: .page, page: 3, maxw: 1600, version: "etag-v1")
        let k1Again = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 7, kind: .page, page: 3, maxw: 1600, version: "etag-v1")
        let k2 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 7, kind: .page, page: 3, maxw: 1600, version: "etag-v2")

        let d1 = try await cache.data(for: k1) { await counter.bump(); return Data([1, 1, 1]) }
        // 同版の再取得＝キャッシュヒット（fetch は呼ばれない・帯域節約が壊れていないことの確認）。
        let d1Again = try await cache.data(for: k1Again) { await counter.bump(); return Data([9, 9, 9]) }
        // relink で etag が変わった想定＝別版はミスして必ず再取得される（stale page を返さない）。
        let d2 = try await cache.data(for: k2) { await counter.bump(); return Data([2, 2, 2]) }

        #expect(d1 == Data([1, 1, 1]))
        #expect(d1Again == Data([1, 1, 1]))   // ヒットなので旧バイトのまま（fetch クロージャの新バイトは無視される）
        #expect(d2 == Data([2, 2, 2]))
        #expect(await counter.count == 2)     // k1 初回 + k2 のみ fetch。k1Again はヒットでカウントされない。
    }

    /// RemoteBookContent の init が version をそのまま保持し公開 accessor から読めることを確認する
    /// （imageData(at:) 内で同じ private version が Key へ渡る配線の土台。実際の Key 構築は
    /// RemoteBookContentTests 側の HTTP スタブ経由テストで確認する）。
    @Test func remoteBookContentRetainsVersion() {
        let session = URLSession(configuration: .ephemeral)
        let client = RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "d", session: session)
        let versioned = RemoteBookContent(client: client, serverID: UUID(), libraryUUID: "u", bookID: 1,
                                           libraryToken: nil, maxWidth: 1600, version: "etag-abc", cache: nil)
        let unversioned = RemoteBookContent(client: client, serverID: UUID(), libraryUUID: "u", bookID: 1,
                                             libraryToken: nil, maxWidth: 1600, cache: nil)
        #expect(versioned.versionValue == "etag-abc")
        #expect(unversioned.versionValue == nil)
    }
}
