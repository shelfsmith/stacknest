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

    // G27a ③: **実在するファイル**は、stored 値が実際の stat 値と食い違っていても live stat が
    // 優先され、stored 値は使われない。修理などでファイルを差し替えたときに ETag が追従して
    // 古い内容の配信が止まる、というのが本修正の目的そのもの（旧実装はここで stored 値の
    // ままにしていたため、差し替えても ETag が変わらず古い内容が配信され続けていた）。
    @Test func etagUsesLiveStatForExistingFileEvenIfStoredValuesDiffer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("real.cbz")
        try Data(repeating: 9, count: 4321).write(to: file)   // 実サイズ 4321

        let r = row(id: 5, path: file.path, fileMtime: 100, fileSize: 50)   // stored は陳腐化した値
        let (liveSize, liveMtime) = Database.statFile(file.path)
        let expectedHash = String(fnv1aHash(file.path), radix: 36)
        #expect(bookETag(for: r) == "\"5-\(Int(liveMtime ?? 0))-\(liveSize ?? 0)-\(expectedHash)\"")
        // stored 値 (100/50) はもう使われないことを明示する。
        #expect(bookETag(for: r) != "\"5-100-50-\(expectedHash)\"")
    }

    // stat 失敗時のフォールバック（レビュー Minor）: ディレクトリとして解決できないパスでは
    // stored 値へ落ちる。NAS の一時的な不調で ETag が "id-0-0" に崩れて全クライアントが
    // 再ダウンロードする事故を防ぐための保険。
    @Test func directoryStatFailureFallsBackToStoredValues() {
        let r = row(id: 6, path: "/nonexistent-dir-xyz", fileMtime: 777, fileSize: 888)
        let expectedHash = String(fnv1aHash("/nonexistent-dir-xyz"), radix: 36)
        #expect(bookETag(for: r) == "\"6-777-888-\(expectedHash)\"")
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

    // 両方揃っている「ファイル」行（アーカイブ本）は、path が実在しなくても stat を経由せず
    // 保存値だけを使う＝churn なし（全クライアント再ダウンロードを招く ETag 変化を起こさない）。
    // 注意: path が存在しない（= isDirectory 判定できない）ため、このケースは
    // effectiveFileStat の「ディレクトリなら常に live stat」分岐を通らず旧来どおり
    // stored 値を使う側に落ちる。ディレクトリ（relink 済みフォルダ本含む）の挙動は
    // 下の etagFollowsDirectoryMtimeEvenWhenStoredStatsPresentAfterRelink で別途検証する。
    @Test func etagUnchangedWhenBothStatsAlreadySet() {
        let path = "/nonexistent/should-not-be-statted.cbz"
        let a = row(id: 7, path: path, fileMtime: 123, fileSize: 456)
        let expectedHash = String(fnv1aHash(path), radix: 36)
        #expect(bookETag(for: a) == "\"7-123-456-\(expectedHash)\"")
    }

    // 実機 smoke 回帰: relinkBook/applyRelinks（G4d 層1）はアーカイブファイル向けに
    // file_mtime/file_size を無条件で書き込む。フォルダ本がこれを一度でも経由すると
    // 両方 non-nil になり、effectiveFileStat の「両方揃っていれば stored 値を使う」旧ロジックの
    // ショートカットに永久に吸い込まれ、以後ディレクトリへ子ファイルを追加/削除しても bookETag が
    // 二度と変化しなくなっていた（実機 id=19 で再現）。
    // ディレクトリは stored 値の有無に関わらず常に request 時 live stat を使うべきで、
    // このテストは「ディレクトリで stored 値ショートカットを復活させると FAIL する」ことを保証する。
    @Test func etagFollowsDirectoryMtimeEvenWhenStoredStatsPresentAfterRelink() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookETag-relinked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: tmp.path)

        // relink 直後を模す: file_mtime/file_size が両方 non-nil（かつ relink 時点の値で）埋まっている行。
        let relinkedFolderRow = row(id: 19, path: tmp.path, fileMtime: 1_000_000, fileSize: 4096)
        let before = bookETag(for: relinkedFolderRow)

        // 直下に子ファイルを追加し、ディレクトリの mtime を進める（archive モードのフォルダ本に
        // ページが増える操作を模す）。row の fileMtime/fileSize は relink 時点のまま更新されない
        // ことが重要（＝実運用でも誰もこれを更新しない）。
        try Data("page".utf8).write(to: tmp.appendingPathComponent("page1.jpg"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: tmp.path)
        let after = bookETag(for: relinkedFolderRow)

        #expect(before != after)
    }
}
