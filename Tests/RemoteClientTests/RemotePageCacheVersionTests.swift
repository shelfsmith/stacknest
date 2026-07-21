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

    /// レビュー Minor4 fix: manifest.etag は HTTP ETag 形式で `"..."` のように前後にクォートを含む文字列
    /// そのものが渡ってくる。RemoteBookContent.init の正規化（唯一の入口）で剥がされ、versionValue は
    /// クォート無しの素の値を返すことを確認する。剥がされないと imageData の Key／setProtected の
    /// 保護キー／cachedPages の版一致判定のいずれかで `v"..."` という汚れた文字列のまま伝播しうる。
    @Test func remoteBookContentNormalizesQuotedETagVersion() {
        let session = URLSession(configuration: .ephemeral)
        let client = RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "d", session: session)
        let quoted = RemoteBookContent(client: client, serverID: UUID(), libraryUUID: "u", bookID: 1,
                                        libraryToken: nil, maxWidth: 1600,
                                        version: "\"5-1700000000-1234-abc\"", cache: nil)
        #expect(quoted.versionValue == "5-1700000000-1234-abc")
        // クォートが無い値（後方互換・非 ETag 由来の版）はそのまま素通しされる。
        let bare = RemoteBookContent(client: client, serverID: UUID(), libraryUUID: "u", bookID: 1,
                                      libraryToken: nil, maxWidth: 1600, version: "plain-version", cache: nil)
        #expect(bare.versionValue == "plain-version")
    }

    // MARK: - cachedPages 版判別（レビュー Important2 fix）

    /// 真の判別テスト: cachedPages は「要求した version と一致する行だけ」を数える。
    /// f.count >= 6 に緩和しただけ（版に関わらず数える）だと、relink 直後は旧版の行が disk に
    /// まだ残っていて「キャッシュ済み」と誤って数えてしまい（実際は全ページがミスして再取得される）、
    /// HUD のカバレッジ帯が過大申告する。この振る舞いは以下のいずれの単純化でも再現できてしまうため、
    /// それぞれを個別にアサーションする:
    ///   - 版を無視して数える（f.count >= 6 のみ）→ 別版の行も混入してしまう
    ///   - 有版行を無版として誤カウントする → nil 版問い合わせで有版行まで混ざってしまう
    @Test func cachedPagesDiscriminatesByVersion() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        let sid = UUID()
        let v1page0 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 3, kind: .page, page: 0, maxw: 1600, version: "v1")
        let v1page1 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 3, kind: .page, page: 1, maxw: 1600, version: "v1")
        let v2page0 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 3, kind: .page, page: 0, maxw: 1600, version: "v2")
        let unversionedPage2 = RemotePageCache.Key(serverID: sid, libraryUUID: "L", bookID: 3, kind: .page, page: 2, maxw: 1600)
        _ = try await cache.data(for: v1page0) { Data(count: 10) }
        _ = try await cache.data(for: v1page1) { Data(count: 10) }
        _ = try await cache.data(for: v2page0) { Data(count: 10) }             // relink 後の新版（page0 のみ再取得済み）
        _ = try await cache.data(for: unversionedPage2) { Data(count: 10) }    // 旧来の無版行（後方互換）

        // relink 直後: v1 の旧版行 (0,1) は disk にまだ残っているが、v2 を要求すれば
        // 実際に v2 でキャッシュ済みの page0 だけが返る（0,1 の stale 行が誤って混入しない）。
        let v2Pages = await cache.cachedPages(serverID: sid, libraryUUID: "L", bookID: 3, maxw: 1600, version: "v2")
        #expect(v2Pages == [0])

        // v1 を要求すれば v1 の行 (0,1) のみ返る。v2 の行や無版行は混入しない。
        let v1Pages = await cache.cachedPages(serverID: sid, libraryUUID: "L", bookID: 3, maxw: 1600, version: "v1")
        #expect(v1Pages == [0, 1])

        // 版を要求しない（nil）場合は無版行のみ返る。有版行（v1/v2）を無版として誤カウントしない。
        let unversionedPages = await cache.cachedPages(serverID: sid, libraryUUID: "L", bookID: 3, maxw: 1600, version: nil)
        #expect(unversionedPages == [2])
    }
}
