// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryStore

@Suite("bookETag")
struct BookETagTests {
    private func row(id: Int, path: String, fileMtime: Double?, fileSize: Int64?) -> BookRow {
        BookRow(
            id: id, title: "Book \(id)", author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            fileSize: fileSize, fileMtime: fileMtime
        )
    }

    @Test func etagChangesWhenPathChangesEvenWithNullStats() {
        // mtime/size が両方 nil でも、path が違えば etag は変わる（null 衝突防止）。
        let a = row(id: 1, path: "/x/a.cbz", fileMtime: nil, fileSize: nil)
        let b = row(id: 1, path: "/x/b.cbz", fileMtime: nil, fileSize: nil)
        #expect(bookETag(for: a) != bookETag(for: b))
    }

    @Test func etagStableForSameContent() {
        let a = row(id: 1, path: "/x/a.cbz", fileMtime: 100, fileSize: 50)
        let b = row(id: 1, path: "/x/a.cbz", fileMtime: 100, fileSize: 50)
        #expect(bookETag(for: a) == bookETag(for: b))
    }

    // 最終レビュー Finding 1: フォルダブック（G9b archive）は dedup スキャンがディレクトリを
    // skip するため file_mtime/file_size が import 後ずっと nil のまま＝旧実装では bookETag が
    // "id-0-0-<pathhash>" に恒久固定され、中身を差し替えても誰にも気付かれなかった。
    // request 時にディレクトリ自身を stat して mtime を代用することで追従することを確認する。
    @Test func etagFollowsDirectoryMtimeWhenStatsAreNilAfterChildAdded() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bookETag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 明示的に mtime を固定してから before を取る（実ファイル作成直後の同一秒内 mtime 差の
        // 揺れに依存しない・決定的なテストにするため）。
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: tmp.path)
        let folderRow = row(id: 42, path: tmp.path, fileMtime: nil, fileSize: nil)
        let before = bookETag(for: folderRow)

        // 直下に子ファイルを1つ追加（archive モードのフォルダ本にページが増える操作を模す）。
        // 実運用ではこの追加自体が OS によりディレクトリの mtime を進める。ここではテストの
        // 決定性のため mtime を明示的に進めて検証する。
        try Data("page".utf8).write(to: tmp.appendingPathComponent("page1.jpg"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: tmp.path)
        let after = bookETag(for: folderRow)

        #expect(before != after)
    }

    // 両方揃っている行（アーカイブファイル本、または relink 済みのフォルダ本）は、実在しない
    // パスであっても stat を経由せず保存値だけを使う＝churn なし（全クライアント再ダウンロード
    // を招く ETag 変化を起こさない）。
    @Test func etagUnchangedWhenBothStatsAlreadySet() {
        let path = "/nonexistent/should-not-be-statted.cbz"
        let a = row(id: 7, path: path, fileMtime: 123, fileSize: 456)
        let expectedHash = String(fnv1aHash(path), radix: 36)
        #expect(bookETag(for: a) == "\"7-123-456-\(expectedHash)\"")
    }
}
