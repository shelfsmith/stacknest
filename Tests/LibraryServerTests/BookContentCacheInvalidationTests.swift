// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryStore

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
}
