// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryStore
import AppCore

/// G4d 層0: BookContentCache が row の content 基準（path/mtime/size）変化を検知して
/// 再構築することの検証。relink 直後に古いアーカイブから読み続ける回帰を防ぐ。
@Suite("BookContentCache invalidation")
struct BookContentCacheInvalidationTests {
    private static func row(
        id: Int, path: String, fileMtime: Double? = nil, fileSize: Int64? = nil,
        rating: Int = 0, title: String = "Book"
    ) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: rating, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            fileSize: fileSize, fileMtime: fileMtime
        )
    }

    /// three_pages.zip（3頁）と two_pages.zip（2頁）を一時ディレクトリへコピーして返す。
    private static func makeTwoArchives() throws -> (dirURL: URL, threePage: URL, twoPage: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcc-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let threeSrc = Bundle.module.url(
            forResource: "three_pages", withExtension: "zip", subdirectory: "Fixtures"
        ), let twoSrc = Bundle.module.url(
            forResource: "two_pages", withExtension: "zip", subdirectory: "Fixtures"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let threeDst = dir.appendingPathComponent("three_pages.zip")
        let twoDst = dir.appendingPathComponent("two_pages.zip")
        try FileManager.default.copyItem(at: threeSrc, to: threeDst)
        try FileManager.default.copyItem(at: twoSrc, to: twoDst)
        return (dir, threeDst, twoDst)
    }

    @Test func rebuildsWhenPathChanges() async throws {
        let (dirURL, threePage, twoPage) = try Self.makeTwoArchives()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let cache = BookContentCache(ttlSeconds: 300)

        let rowA = Self.row(id: 7, path: threePage.path)
        let c1 = try await cache.content(for: rowA, libraryUUID: "L")
        let n1 = try await c1.pageCount
        #expect(n1 == 3)

        // 同じ id・異なる path（relink 後の状態を模す）で再取得すると再構築されるべき。
        let rowB = Self.row(id: 7, path: twoPage.path)
        let c2 = try await cache.content(for: rowB, libraryUUID: "L")
        let n2 = try await c2.pageCount
        #expect(n2 == 2)   // 再構築されず 3 のままなら FAIL（現状バグ）
    }

    /// rating/title だけの変化では basis (path/mtime/size) が同一なので再構築されないこと。
    /// 「再構築されていない」ことを外部から見分けるため、1回目のアクセスでアーカイブの
    /// エントリ一覧を読ませてから元ファイルを削除する。もし2回目のアクセスで
    /// BookContentFactory.make が呼ばれ直していれば、削除済みファイルを開こうとして
    /// invalidPath で失敗するはず。既存エントリが再利用されれば、キャッシュ済みの
    /// entryNames から pageCount がディスクアクセスなしで返り、成功し続ける。
    @Test func doesNotRebuildWhenOnlyNonContentFieldsChange() async throws {
        let (dirURL, threePage, _) = try Self.makeTwoArchives()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let cache = BookContentCache(ttlSeconds: 300)

        let rowA = Self.row(id: 9, path: threePage.path, rating: 0, title: "Original Title")
        let c1 = try await cache.content(for: rowA, libraryUUID: "L")
        let n1 = try await c1.pageCount   // エントリ一覧をロードさせてキャッシュさせる
        #expect(n1 == 3)

        // 原本ファイルを削除。再構築が起きればここで開こうとして invalidPath で失敗する。
        try FileManager.default.removeItem(at: threePage)

        // path/mtime/size は不変。rating・title だけ変わった row（編集操作を模す）。
        let rowEdited = Self.row(id: 9, path: threePage.path, rating: 5, title: "Renamed")
        let c2 = try await cache.content(for: rowEdited, libraryUUID: "L")
        let n2 = try await c2.pageCount   // 再構築されていなければキャッシュ済み entryNames から返る
        #expect(n2 == 3)
    }

    /// 実機 smoke 回帰の核心（id=19）: フォルダ本が relink を経由すると file_mtime/file_size が
    /// 両方 non-nil で固定される。basis 計算（effectiveFileStat）がディレクトリでも stored 値を
    /// 優先してしまうと、この Entry.basis が二度と変化せず、直下へ子ファイルを追加しても
    /// 古い FolderBookContent（＝古い entryNames）を返し続けてしまう。
    /// このテストは、basis がディレクトリの live mtime を反映して変化し、キャッシュが
    /// 再構築されて新しい pageCount を返すことを保証する。stored 値ショートカットが
    /// ディレクトリにも適用されるよう effectiveFileStat を戻すと FAIL する。
    @Test func rebuildsForRelinkedFolderBookWhenDirectoryMtimeChanges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcc-folder-relinked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 {
            try Data("page\(i)".utf8).write(to: dir.appendingPathComponent("page\(i).jpg"))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: dir.path)

        let cache = BookContentCache(ttlSeconds: 300)
        // relink 直後を模す: file_mtime/file_size が両方 non-nil（relink 時点の値）で埋まった行。
        let relinkedRow = Self.row(id: 19, path: dir.path, fileMtime: 1_000_000, fileSize: 4096)
        let c1 = try await cache.content(for: relinkedRow, libraryUUID: "L")
        let n1 = try await c1.pageCount
        #expect(n1 == 3)

        // 4枚目を追加し、ディレクトリ mtime を進める。row 自体（stored fileMtime/fileSize）は
        // relink 時点のまま不変（＝実運用で誰も更新しない状態を模す）。
        try Data("page3".utf8).write(to: dir.appendingPathComponent("page3.jpg"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: dir.path)

        let c2 = try await cache.content(for: relinkedRow, libraryUUID: "L")
        let n2 = try await c2.pageCount
        #expect(n2 == 4)   // 3 のままなら basis が凍結＝FAIL（本 Finding の核心）
    }

    /// manifest 修正（BookContentFactory.make → contentCache 経由）の「同じ源から読む」不変条件を
    /// 本レイヤーで直接示す。
    ///
    /// 検証メモ（本テストを書く過程で確認した事実）: このテストでは当初、ディレクトリ mtime を
    /// 明示的に据え置いたまま子ファイルを追加し、「同一 mtime 内の変更＝basis 不変」というレースを
    /// 再現しようとした。だが APFS では、ディレクトリ自身の `size` 属性がエントリ数の増減に応じて
    /// 直ちに変化する（実測: 3 エントリ=160 bytes → 4 エントリ=192 bytes、mtime を強制的に同一値へ
    /// 戻しても size は変わったまま）。つまりこの環境では、effectiveFileStat の live-stat 修正
    /// （修正1）の basis（mtime **と** size の両方を見る）だけで、実ファイル操作で起こせる
    /// エントリ数変化は必ず捕捉されてしまい、「修正1はすり抜けるが修正2なら防げる」という
    /// 純粋な FS レース条件をこの環境で作為的に再現することはできなかった。
    /// そのため、修正2固有の「manifest と pages が食い違う」ケースを実ファイル操作だけで
    /// 決定的に落とすユニットテストは用意していない（用意しようとしたテストは前提が誤りだったため
    /// 削除した）。
    /// 代わりに、修正2 が保証する構造的事実——manifest ルートと pages ルートが**同一の**
    /// `contentCache.content(for:libraryUUID:)` 呼び出し（同じ key・同じ basis）を経由すること——を
    /// 直接検証する。同じ key で 2 回呼べば必ず同一インスタンスが返ることを確認し、対照として
    /// `BookContentFactory.make` は呼ぶたびに新規インスタンスを生成する（＝キャッシュを共有しない）
    /// ことも示す。ContentEndpointTests.swift の
    /// `manifestAndPagesAgreeForRelinkedFolderBookAfterChildAdded`（エンドポイント E2E）が
    /// 実際の manifest/pages 食い違いバグ（修正1が主因）の回帰を検出する主テストであり、
    /// 本テストはその上で「manifest が pages と同じキャッシュ経路を通る」という設計の柱を保証する。
    @Test func cacheReturnsIdenticalInstanceForSameBasisUnlikeFactoryMake() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcc-manifest-vs-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 {
            try Data("page\(i)".utf8).write(to: dir.appendingPathComponent("page\(i).jpg"))
        }

        let cache = BookContentCache(ttlSeconds: 300)
        let row = Self.row(id: 21, path: dir.path)

        // 修正後の manifest 相当と pages/:n 相当: どちらも同じ contentCache.content(for:libraryUUID:)
        // を呼ぶ。basis（path/mtime/size）が変化していない限り、必ず同一インスタンスが返る
        // ＝ pageCount も entryNames も常に同じ実体由来になる（このテストの本旨）。
        let manifestContentViaCache = try await cache.content(for: row, libraryUUID: "L")
        let pagesContentViaCache = try await cache.content(for: row, libraryUUID: "L")
        let sameInstance = (manifestContentViaCache as AnyObject) === (pagesContentViaCache as AnyObject)
        #expect(sameInstance)

        // 対照: 修正前の manifest 相当（BookContentFactory.make 直呼び）は、キャッシュを介さない
        // ため呼ぶたびに新規インスタンスを生成する。今は中身が同じでも「同じ源から読む」という
        // 保証は構造的に存在せず、将来ディレクトリが変化するタイミング次第で pages 側の
        // キャッシュ済みインスタンスと食い違いうる（実機 smoke で実際に起きた形）。
        let freshFactory1 = try BookContentFactory.make(for: row)
        let freshFactory2 = try BookContentFactory.make(for: row)
        let factorySharesInstance = (freshFactory1 as AnyObject) === (freshFactory2 as AnyObject)
        #expect(!factorySharesInstance)
    }
}
