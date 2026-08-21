// SPDX-License-Identifier: MIT
//
// Thread-safety: GRDB's DatabaseQueue serializes all DB access internally.
// `queue` is set in init and cleared in close(); no concurrent writes
// expected at the T11 stage. Revisit when LibraryImporter (T16) introduces
// concurrent writers.

import Foundation
import GRDB
import StackroomFormat

public enum OpenMode: Sendable {
    case createOrFail
    case createOrReplace
}

/// Database 操作固有のエラー型。
public enum DatabaseError: Error, Sendable {
    /// マルチ値対象外のカラムに addToBookField / clearBookField を呼んだ。
    case invalidColumn(String)
    /// G27a Fix5: queue が nil＝ライブラリが閉じている状態で書き込みを試みた。
    /// upsertIntegrity / updateBookFileStat はこれを黙って return せず throw する
    /// （走査中に close されると、何も書けていないのに成功したかのような集計になってしまうため）。
    case libraryClosed
}

public struct BookRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let author: String?
    public let genre: String?
    public let path: String?
    public let dateAdded: Date
    public let playDate: Date?
    public let bookType: Int
    public let fileType: Int
    public let pages: Int?
    public let rating: Int
    public let unseen: Bool
    public let keywordA: String?
    public let keywordB: String?
    public let keywordC: String?
    public let neta: String?
    public let memo: String?
    public let series: String?
    public let volume: Double?
    public let coverImageName: String?
    public let coverCropRect: CGRect?
    /// Phase 2.6b-2 D1: per-book page direction. nil = inherit global setting.
    public let pageDirection: PageDirection?
    /// Phase 2.7 A20/B11: SHA-256 (hex) of the source file. nil = not computed / not eligible (folder/missing).
    public let contentHash: String?
    /// File size (bytes) at hash time. Used for size-prefilter and cache invalidation.
    public let fileSize: Int64?
    /// File mtime (epoch seconds) at hash time. Used for cache invalidation.
    public let fileMtime: Double?

    /// Public memberwise initializer. Provided so external library callers
    /// (notably AppCoreTests fixtures) can construct BookRow values outside
    /// of `Database.fetchAllBooks()`. Production reads always go through the
    /// SQL row decoder.
    public init(
        id: Int,
        title: String,
        author: String?,
        genre: String?,
        path: String?,
        dateAdded: Date,
        playDate: Date?,
        bookType: Int,
        fileType: Int,
        pages: Int?,
        rating: Int,
        unseen: Bool,
        keywordA: String?,
        keywordB: String?,
        keywordC: String?,
        neta: String?,
        memo: String? = nil,
        series: String? = nil,
        volume: Double? = nil,
        coverImageName: String? = nil,
        coverCropRect: CGRect? = nil,
        pageDirection: PageDirection? = nil,
        contentHash: String? = nil,
        fileSize: Int64? = nil,
        fileMtime: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.genre = genre
        self.path = path
        self.dateAdded = dateAdded
        self.playDate = playDate
        self.bookType = bookType
        self.fileType = fileType
        self.pages = pages
        self.rating = rating
        self.unseen = unseen
        self.keywordA = keywordA
        self.keywordB = keywordB
        self.keywordC = keywordC
        self.neta = neta
        self.memo = memo
        self.series = series
        self.volume = volume
        self.coverImageName = coverImageName
        self.coverCropRect = coverCropRect
        self.pageDirection = pageDirection
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.fileMtime = fileMtime
    }

    /// JSON `{"x":...,"y":...,"w":...,"h":...}` を CGRect に復号。`nil` / 空 / 不正 JSON は nil。
    public static func decodeCoverCropRect(json: String?) -> CGRect? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// CGRect を JSON `{"x":...,"y":...,"w":...,"h":...}` 文字列に符号化。
    public static func encodeCoverCropRect(_ rect: CGRect) -> String {
        let dict: [String: Double] = [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "w": Double(rect.size.width),
            "h": Double(rect.size.height)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            preconditionFailure("encodeCoverCropRect: failed to serialize \(rect) — non-finite or invalid value")
        }
        return s
    }

    /// 詳細ペイン表紙ビューの再描画 identity（SwiftUI `.id()` 用）。
    /// 表紙メタ（名前・crop）に加えて `coverVersion` を含める。外部画像を差し替えても
    /// coverImageName="@external" のままメタが不変なケースで、cover 書き込みごとに増える
    /// coverVersion が変化することで view identity が更新され、キャッシュ無効化後に
    /// 再描画/再取得される（G4b smoke で判明した stale 修正）。
    public func coverRenderIdentity(coverVersion: Int) -> String {
        let crop = coverCropRect.map {
            "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)"
        } ?? ""
        return "\(id):\(coverImageName ?? ""):\(crop):\(coverVersion)"
    }

    /// 表紙画像の再取得トリガ identity（SwiftUI `.task(id:)` 用）。
    /// 画像の再取得は切り抜き（crop）に依存しないため crop は含めない。
    public func coverFetchIdentity(coverVersion: Int) -> String {
        "\(id):\(coverImageName ?? ""):\(coverVersion)"
    }
}

/// Per-book viewer state as persisted in `book_viewer_state` + `book_page_layout`.
/// `overrides` maps page_index → raw mode int (0 = forcePair, 1 = forceSolo).
/// LibraryStore does not depend on AppCore, so the App layer maps these raw
/// ints to/from `PageLayoutOverride`.
public struct StoredViewerState: Sendable, Equatable {
    public var spreadEnabled: Bool
    public var coverOffset: Bool
    public var lastPage: Int
    public var overrides: [Int: Int]
    /// Phase 2.6b-2 T5: book_viewer_state テーブルに実際の行が存在するか。
    /// false = 行なし（デフォルト値が適用されている）。
    /// App 層はこれを見て spread の初期値に spreadByDefault を適用するか決定する。
    public var hasPersistedState: Bool
    /// G17 T6a: `spreadEnabled` がユーザーの明示操作（ネイティブ `saveViewerState`）で
    /// 書かれたものかどうか。false は「行はあるが spread は未確定」（例: リモート
    /// progress writeback だけで作られた行）を意味し、App 層はこの場合
    /// spreadByDefault にフォールバックすべきで `spreadEnabled` を信用してはいけない。
    public var spreadExplicit: Bool

    public init(
        spreadEnabled: Bool = false,
        coverOffset: Bool = true,
        lastPage: Int = 0,
        overrides: [Int: Int] = [:],
        hasPersistedState: Bool = false,
        spreadExplicit: Bool = false
    ) {
        self.spreadEnabled = spreadEnabled
        self.coverOffset = coverOffset
        self.lastPage = lastPage
        self.overrides = overrides
        self.hasPersistedState = hasPersistedState
        self.spreadExplicit = spreadExplicit
    }
}

public enum SidebarScope: Sendable {
    case library
    case favorites(playlistID: Int64)
    case recent(days: Int)
    case shelf(playlistID: Int64)
    case smartShelf(playlistID: Int64)
}

public struct PlaylistRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let title: String
    public let kind: String   // "imported" / "user" / "favorites"
    public let icon: Int?
    public let itemView: Bool
    public let toolTab: Bool
    public let isSmart: Bool

    public init(id: Int64, title: String, kind: String, icon: Int? = nil,
                itemView: Bool = false, toolTab: Bool = false, isSmart: Bool = false) {
        self.id = id; self.title = title; self.kind = kind
        self.icon = icon; self.itemView = itemView; self.toolTab = toolTab
        self.isSmart = isSmart
    }
}

public final class Database: @unchecked Sendable {
    // Read is internal, write stays file-scoped: Database+Integrity.swift (and any future
    // same-module Database+*.swift extension file) only ever reads the queue (`guard let q =
    // queue`), never assigns it. `private` in Swift is scoped to the declaring *file*, so a
    // plain `private var` would hide the read from those extensions too — but a plain internal
    // `var` would let any file in this module reassign `queue` directly, which would desync it
    // from `isOpen` (only `init` and `close()`, both in this file, are allowed to write `queue`,
    // and `close()` always pairs `queue = nil` with `isOpen = false`). `private(set)` gives
    // module-wide read access while keeping the setter private to this file.
    /// ★ `queue` の読み書きはロックで直列化する（G35 Codex 4 巡目 P1）。
    ///
    /// 従来は素の `var` で、読み手も書き手も MainActor 上にいたため競合しなかった。
    /// G35 で監視フォルダの走査（`allBookPaths`）がオフスレッドへ移り、
    /// **`close()` が `queue = nil` を書くのと並行して読まれる**ようになった。
    /// strong reference の並行読み書きは ARC の retain/release が壊れうるので、
    /// 論理的な競合では済まず**メモリ安全性の問題**になる。
    ///
    /// 読み出しを同期化すれば、呼び出し側が `guard let q = queue` で得た強参照は
    /// その処理の間 ARC が生かし続ける（`close()` が後からプロパティを nil にしても、
    /// 実行中の処理は自分の `q` を安全に使い切れる。GRDB の `DatabaseQueue` は
    /// 内部で直列化しているので、複数の利用者が居ても安全）。
    ///
    /// **`queue` へ直接触れてよいのは `init` と `close()` だけ**という従来の規律は変えていない
    /// （`_queue` はこのファイル内に閉じ、他の `Database+*.swift` からは読み取り専用の
    /// `queue` しか見えない）。
    private let queueLock = NSLock()
    private var _queue: DatabaseQueue?

    var queue: DatabaseQueue? {
        queueLock.lock()
        defer { queueLock.unlock() }
        return _queue
    }

    public private(set) var isOpen: Bool = false

    /// Seconds in one day. Used for all date-cutoff arithmetic
    /// (`.recent(days:)`, FilterState date ranges, smart-shelf date rules).
    static let secondsPerDay: Double = 86_400

    private init(queue: DatabaseQueue) {
        self._queue = queue
        self.isOpen = true
    }

    /// GRDB Configuration that enables SQLite FK enforcement on every connection.
    ///
    /// - Parameter busyTimeout: 競合時に待つ秒数。`nil` なら GRDB の既定
    ///   （`.immediateError` ＝ 即失敗）のまま。
    ///
    /// **既定を変えないこと（G37 ①）。** この関数は本庫 DB を含む**全オープン経路が共有**する。
    /// 本庫 DB は `LibraryOpenLock` が同時に 1 インスタンスへ限定しており競合がほぼ無い一方、
    /// 書き込みは MainActor からも行われるため、待たせると**メインスレッドを最大 N 秒止めうる**
    /// ―― G35/G36 が減らしてきたものを戻す方向になる。**待たせるべき場所だけ待たせる。**
    private static func makeConfiguration(busyTimeout: TimeInterval? = nil) -> Configuration {
        var config = Configuration()
        if let busyTimeout {
            config.busyMode = .timeout(busyTimeout)
        }
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    public static func openInMemory(busyTimeout: TimeInterval? = nil) throws -> Database {
        let q = try DatabaseQueue(configuration: makeConfiguration(busyTimeout: busyTimeout))
        return Database(queue: q)
    }

    public static func openFile(at url: URL, mode: OpenMode,
                                busyTimeout: TimeInterval? = nil) throws -> Database {
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch mode {
        case .createOrFail:
            if exists { throw ImportError.dbExistsWithoutForce(url) }
        case .createOrReplace:
            if exists {
                try FileManager.default.removeItem(at: url)
            }
        }
        let q = try DatabaseQueue(path: url.path,
                                  configuration: makeConfiguration(busyTimeout: busyTimeout))
        return Database(queue: q)
    }

    public static func openExisting(at url: URL,
                                    busyTimeout: TimeInterval? = nil) throws -> Database {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.dbNotFound(url)
        }
        let q = try DatabaseQueue(path: url.path,
                                  configuration: makeConfiguration(busyTimeout: busyTimeout))
        return Database(queue: q)
    }

    public func migrate() throws {
        guard let q = queue else { return }
        try q.write { try Migration.apply(to: $0) }
    }

    // MARK: - Integrity & Backup (Phase 2.8 B22)

    /// `PRAGMA quick_check` — lightweight integrity probe. Returns true iff the
    /// single result row is exactly "ok".
    public func quickCheck() throws -> Bool {
        guard let q = queue else { return false }
        do {
            return try q.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"]
            }
        } catch {
            // 破損 (SQLITE_CORRUPT 等) は PRAGMA 実行時にエラーとして送出される。
            // 健全性チェックの目的上、検証に失敗したら「異常」とみなして false を返し、
            // 生エラーを伝播させない（呼び出し側がバックアップ復元を提案できるようにする）。
            return false
        }
    }

    /// `PRAGMA integrity_check` — full scan. Returns the result rows
    /// (`["ok"]` when healthy, otherwise one row per problem found).
    public func integrityCheck() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check")
        }
    }

    /// SQLite Online Backup API による一貫スナップショット。WAL/journal を伴わない
    /// 単体で開ける独立 .sqlite を `url` に書き出す。
    /// 一意な世代名で呼ぶ前提。同名ファイルが既にあると上書きされる点に注意。
    public func backup(to url: URL) throws {
        guard let q = queue else { return }
        let dest = try DatabaseQueue(path: url.path)
        try q.backup(to: dest)
    }

    public func insertBook(_ book: BookRecord) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: Tables.insertBookSQL,
                arguments: [
                    book.id,
                    TextNormalize.nfcValue(book.title),
                    TextNormalize.nfcValue(book.author),
                    TextNormalize.nfcValue(book.genre),
                    book.path,                       // path: do NOT normalize (filesystem ref)
                    book.dateAdded.timeIntervalSince1970,
                    book.playDate?.timeIntervalSince1970,
                    book.bookType,
                    book.fileType,
                    book.pages,
                    book.myRate,
                    book.unseen ? 1 : 0,
                    TextNormalize.nfcValue(book.keywordA),
                    TextNormalize.nfcValue(book.keywordB),
                    TextNormalize.nfcValue(book.keywordC),
                    TextNormalize.nfcValue(book.neta),
                    nil as String?,                  // memo
                    TextNormalize.nfcValue(book.series),
                    book.volume,
                    book.coverImageName,             // coverImageName: do NOT normalize (FS ref)
                    nil as String?,                  // cover_crop_rect: BookRecord has no crop data (import path)
                    nil as String?,                  // page_direction: BookRecord has no per-book override (import path)
                    nil as String?,                  // content_hash: computed later, not at import time
                    nil as Int64?,                   // file_size: computed later, not at import time
                    nil as Double?,                  // file_mtime: computed later, not at import time
                ]
            )
        }
    }

    /// Inserts a new book with auto-assigned id and returns the new row id.
    /// Pass id=nil to let SQLite assign the ROWID automatically.
    /// Used by BookAddCoordinator for the add-book pipeline.
    public func insertBookReturningID(_ book: BookRecord) throws -> Int {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        return try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO book (title, author, genre, path, date_added, play_date, book_type, file_type, pages, rating, unseen, keyword_a, keyword_b, keyword_c, neta, memo, series, volume, cover_image_name)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    TextNormalize.nfcValue(book.title),
                    TextNormalize.nfcValue(book.author),
                    TextNormalize.nfcValue(book.genre),
                    book.path,                       // path: do NOT normalize (filesystem ref)
                    book.dateAdded.timeIntervalSince1970,
                    book.playDate?.timeIntervalSince1970,
                    book.bookType,
                    book.fileType,
                    book.pages,
                    book.myRate,
                    book.unseen ? 1 : 0,
                    TextNormalize.nfcValue(book.keywordA),
                    TextNormalize.nfcValue(book.keywordB),
                    TextNormalize.nfcValue(book.keywordC),
                    TextNormalize.nfcValue(book.neta),
                    nil as String?,                  // memo
                    TextNormalize.nfcValue(book.series),
                    book.volume,
                    book.coverImageName,             // coverImageName: do NOT normalize (FS ref)
                ]
            )
            return Int(db.lastInsertedRowID)
        }
    }

    public func fetchBookCount() throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book") ?? 0
        }
    }

    /// 「追加から N 日以内」の書籍数を COUNT で取得（recent バッジ用、行をマテリアライズしない）。
    public func fetchRecentBookCount(days: Int) throws -> Int {
        guard let q = queue else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * Self.secondsPerDay
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book WHERE date_added >= ?", arguments: [cutoff]) ?? 0
        }
    }

    /// `bookRow(from:)` が読む book テーブルの全列。BookRow を返す SELECT は
    /// すべてこの 1 か所を参照する（以前は同じリストが 16 か所にコピペされていた）。
    /// `bookRow(from:)` は列名で読むため SELECT の順序は結果に影響しないが、
    /// 既存 SQL との差分を最小にするため元の順序を保っている。
    private static let bookColumnList = [
        "id", "title", "author", "genre", "path", "date_added", "play_date",
        "book_type", "file_type", "pages", "rating", "unseen", "keyword_a",
        "keyword_b", "keyword_c", "neta", "memo", "series", "volume",
        "cover_image_name", "cover_crop_rect", "page_direction",
        "content_hash", "file_size", "file_mtime",
    ]

    /// `FROM book`（別名なし）用の SELECT リスト。
    private static let bookColumns = bookColumnList.joined(separator: ", ")

    /// `FROM book b` 用の SELECT リスト（`b.` 前置）。JOIN を伴う SQL で使う。
    private static let bookColumnsB = bookColumnList.map { "b.\($0)" }.joined(separator: ", ")

    /// Maps a SQL row to BookRow. Centralized to keep column ordering consistent
    /// across fetchFirstBookRow / fetchAllBooks / fetchBook(id:).
    private static func bookRow(from row: Row) -> BookRow {
        let dateAddedEpoch: Double = row["date_added"]
        let playDateEpoch: Double? = row["play_date"]
        let unseenInt: Int = row["unseen"]
        return BookRow(
            id: row["id"],
            title: row["title"],
            author: row["author"],
            genre: row["genre"],
            path: row["path"],
            dateAdded: Date(timeIntervalSince1970: dateAddedEpoch),
            playDate: playDateEpoch.map(Date.init(timeIntervalSince1970:)),
            bookType: row["book_type"],
            fileType: row["file_type"],
            pages: row["pages"],
            rating: row["rating"],
            unseen: unseenInt != 0,
            keywordA: row["keyword_a"],
            keywordB: row["keyword_b"],
            keywordC: row["keyword_c"],
            neta: row["neta"],
            memo: row["memo"],
            series: row["series"],
            volume: row["volume"],
            coverImageName: row["cover_image_name"] as? String,
            coverCropRect: BookRow.decodeCoverCropRect(json: row["cover_crop_rect"] as? String),
            // nil when column absent (pre-v14 DB) or value invalid; never defaults to .rightToLeft here
            pageDirection: (row["page_direction"] as? String).flatMap(PageDirection.init(rawValue:)),
            // Phase 2.7 A20/B11: nil when column absent from this SELECT or NULL in DB.
            contentHash: row["content_hash"],
            fileSize: row["file_size"],
            fileMtime: row["file_mtime"]
        )
    }

    public func fetchFirstBookRow() throws -> BookRow? {
        guard let q = queue else { return nil }
        return try q.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT \(Self.bookColumns) FROM book ORDER BY id LIMIT 1"
            )
            return row.map(Self.bookRow(from:))
        }
    }

    /// 登録済みの本のパスだけを集合で返す（G35a-1）。
    ///
    /// 監視フォルダの走査は「このパスは既にライブラリにあるか」しか要らないのに、
    /// 従来は `fetchAllBooks()` で**全 24 カラム × 全行を `BookRow` にデコード**していた
    /// （一般コミック 10,752 冊 ＋ e_comic 12,180 冊、しかも `@MainActor` 上で 60 秒ごと）。
    /// 必要な 1 列だけを読む。
    ///
    /// `path` が nil の本は**含めない** ―― 用途が存在判定なので、nil は「どのパスとも一致しない」
    /// が正しい（`fetchAllBooks()` から `compactMap { $0.path }` するのと同じ母集合）。
    public func allBookPaths() throws -> Set<String> {
        guard let q = queue else { return [] }
        return try q.read { db in
            var result: Set<String> = []
            let cursor = try String.fetchCursor(
                db, sql: "SELECT path FROM book WHERE path IS NOT NULL")
            while let path = try cursor.next() {
                result.insert(path)
            }
            return result
        }
    }

    public func fetchAllBooks() throws -> [BookRow] {
        guard let q = queue else { return [] }
        return try q.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: "SELECT \(Self.bookColumns) FROM book ORDER BY date_added DESC"
            )
            var result: [BookRow] = []
            while let row = try cursor.next() {
                result.append(Self.bookRow(from: row))
            }
            return result
        }
    }

    /// Books added within the last `days` days (Stackroom-faithful "最近の項目"
    /// = Date-Added(within) smart playlist), ordered by date_added DESC.
    public func fetchRecentBooks(days: Int) throws -> [BookRow] {
        guard let q = queue else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * Self.secondsPerDay
        return try q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.bookColumns) FROM book WHERE date_added >= ? ORDER BY date_added DESC",
                arguments: [cutoff]
            )
            return rows.map { Self.bookRow(from: $0) }
        }
    }

    public func fetchBook(id: Int) throws -> BookRow? {
        guard let q = queue else { return nil }
        return try q.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT \(Self.bookColumns) FROM book WHERE id = ?",
                arguments: [id]
            )
            return row.map(Self.bookRow(from:))
        }
    }


    public func insertPlaylist(_ playlist: PlaylistRecord) throws {
        guard let q = queue else { return }
        try q.write { db in
            let conditionsBlob: Data? = try playlist.conditions.flatMap {
                try JSONEncoder().encode($0)
            }
            try db.execute(
                sql: Tables.insertPlaylistSQL,
                arguments: [
                    playlist.title,
                    playlist.type,
                    playlist.icon,
                    playlist.itemView ? 1 : 0,
                    playlist.toolTab  ? 1 : 0,
                    conditionsBlob,
                ]
            )
            let playlistID = db.lastInsertedRowID
            for (i, bookID) in playlist.items.enumerated() {
                try db.execute(
                    sql: Tables.insertPlaylistItemSQL,
                    arguments: [playlistID, bookID, i]
                )
            }
        }
    }

    public func fetchPlaylistCount() throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0
        }
    }

    public func fetchPlaylistItemCount() throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item") ?? 0
        }
    }

    public func writeImportMeta(_ meta: ImportMeta) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "DELETE FROM import_meta")
            try db.execute(
                sql: Tables.insertImportMetaSQL,
                arguments: [
                    meta.schemaVersion,
                    meta.importedAt.timeIntervalSince1970,
                    meta.sourceXMLPath,
                    meta.sourceXMLMTime.timeIntervalSince1970,
                    meta.importerVersion,
                    meta.bookCount,
                    meta.skippedCount,
                    meta.notes,
                ]
            )
        }
    }

    public func fetchImportMeta() throws -> ImportMeta? {
        guard let q = queue else { return nil }
        return try q.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM import_meta LIMIT 1") else { return nil }
            return ImportMeta(
                schemaVersion: row["schema_version"],
                importedAt: Date(timeIntervalSince1970: row["imported_at"]),
                sourceXMLPath: row["source_xml_path"],
                sourceXMLMTime: Date(timeIntervalSince1970: row["source_xml_mtime"]),
                importerVersion: row["importer_version"],
                bookCount: row["book_count"],
                skippedCount: row["skipped_count"],
                notes: row["notes"]
            )
        }
    }

    public func fetchImportMetaColumnNames() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(import_meta)")
                .compactMap { $0["name"] as? String }
        }
    }

    public func fetchPlaylistColumnNames() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(playlist)")
                .compactMap { $0["name"] as? String }
        }
    }

    public func fetchBookColumnNames() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(book)")
                .compactMap { $0["name"] as? String }
        }
    }

    /// Test helper: returns the column names of book_fts virtual table.
    public func fetchFTSColumns() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(book_fts)")
                .compactMap { $0["name"] as? String }
        }
    }

    /// Test helper: returns the names of all indexes on the book table.
    public func fetchIndexNames() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='book'"
            )
        }
    }

    /// Test helper: returns column names for a given table via PRAGMA table_info.
    public func fetchTableColumnNames(tableName: String) throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                .compactMap { $0["name"] as? String }
        }
    }

    /// Test helper: returns the CREATE SQL of book_fts virtual table from sqlite_master.
    public func fetchFTSCreateSQL() throws -> String {
        guard let q = queue else { return "" }
        return try q.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='book_fts'"
            ) ?? ""
        }
    }

    /// Test helper: returns the count of book_fts table entries in sqlite_master.
    public func fetchFTSTableCount() throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='book_fts'"
            ) ?? 0
        }
    }

    public func fetchTableNames() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','virtual') ORDER BY name")
        }
    }

    public func fetchFTSCount() throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_fts") ?? 0
        }
    }

    public func deleteBook(id: Int) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [id])
        }
    }

    /// Phase 2.7 A20/B11: write the computed content hash + size/mtime for a single book.
    public func updateBookContentHash(id: Int, hash: String, size: Int64, mtime: Double) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET content_hash = ?, file_size = ?, file_mtime = ? WHERE id = ?",
                arguments: [hash, size, mtime, id]
            )
        }
    }

    // MARK: - Multi-value field mutations

    /// マルチ値 field に値を append。重複は skip。
    /// 対象 column は genre/author/neta/keyword_a/b/c のみ (whitelist)、それ以外は throw。
    /// Returns true if added, false if duplicate.
    public func addToBookField(id: Int, column: String, value: String) throws -> Bool {
        try Self.validateMultiValueColumn(column)
        guard let q = queue else { return false }
        return try q.write { db in
            let current = try String.fetchOne(db, sql: "SELECT \(column) FROM book WHERE id = ?", arguments: [id])
            let (updated, didAdd) = MultiValueParser.append(to: current, value: TextNormalize.nfc(value))
            if didAdd {
                try db.execute(sql: "UPDATE book SET \(column) = ? WHERE id = ?", arguments: [updated, id])
            }
            return didAdd
        }
    }

    /// マルチ値 field を NULL にクリア。
    public func clearBookField(id: Int, column: String) throws {
        try Self.validateMultiValueColumn(column)
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET \(column) = NULL WHERE id = ?", arguments: [id])
        }
    }

    /// whitelist バリデーション。multiValueColumns を共用する。
    private static func validateMultiValueColumn(_ column: String) throws {
        _ = try validatedColumn(column, allowed: multiValueColumns)
    }

    /// SQL カラム識別子の共通バリデーションヘルパ（#16 セキュリティ強化・defense-in-depth）。
    /// 値は bind パラメータ化できるが、カラム識別子は SQLite の性質上どうしても文字列補間する
    /// しかない。呼び出し元（LibraryServerCore の `allowedFacetColumns` / BrowserPaneState.BrowseField
    /// など）が既に許可リストで絞っているが、この境界（LibraryStore）でも独立に検証し、
    /// 未知の識別子は補間前に throw する。`column` を補間する全ての SQL builder はこの関数を経由する。
    /// internal（非 private）: LibraryStoreTests から直接ユニットテストするため。
    static func validatedColumn(_ column: String, allowed: Set<String>) throws -> String {
        guard allowed.contains(column) else {
            throw DatabaseError.invalidColumn(column)
        }
        return column
    }

    /// distinctValues(forColumn:) / buildBrowserClause(_:) が受け付けるカラム識別子の許可リスト。
    /// BrowserPaneState.BrowseField.allCases.map { $0.sqlColumn }（genre/series/author/neta/
    /// keyword_a/b/c）に加え、buildBrowserClause が整数カラムとして特別扱いする rating/book_type
    /// を含む（LibraryStore は AppCore に依存できないため、実際の book テーブルカラムから直接
    /// 定義する。上記 enum の変更時は両方を同期すること）。
    private static let browseColumns: Set<String> = [
        "genre", "series", "author", "neta", "keyword_a", "keyword_b", "keyword_c",
        "rating", "book_type",
    ]

    public func updateBookPath(id: Int, newPath: String) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET path = ? WHERE id = ?",
                arguments: [newPath, id]
            )
        }
    }

    /// 再リンク: path を更新。旧 content_hash は無効化（NULL）するが、file_mtime/file_size は
    /// 新ファイルを即 stat してセットする（G4d: bookETag が relink 直後に決定的に変わり、
    /// リモートの stale ページを防ぐ。stat 失敗時のみ NULL）。
    public func relinkBook(id: Int, newPath: String) throws {
        guard let q = queue else { return }
        let (size, mtime) = Self.statFile(newPath)
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET path = ?, content_hash = NULL, file_size = ?, file_mtime = ? WHERE id = ?",
                arguments: [newPath, size, mtime, id]
            )
        }
    }

    /// 複数本の再リンクを 1 トランザクションで適用（フォルダ再マップ用）。
    /// 各ペアの新パスを即 stat し、file_size/file_mtime を同期セットする（G4d、relinkBook と同じ理由）。
    public func applyRelinks(_ pairs: [(id: Int, newPath: String)]) throws {
        guard let q = queue else { return }
        let stats = pairs.map { Self.statFile($0.newPath) }
        try q.write { db in
            for (i, pair) in pairs.enumerated() {
                let (size, mtime) = stats[i]
                try db.execute(
                    sql: "UPDATE book SET path = ?, content_hash = NULL, file_size = ?, file_mtime = ? WHERE id = ?",
                    arguments: [pair.newPath, size, mtime, pair.id]
                )
            }
        }
    }

    /// 新パスの size(bytes)/mtime(epoch秒) を返す。取得不能なら (nil, nil)。
    /// public: LibraryServer 側（ContentEndpoints.effectiveFileStat, G4d 最終レビュー Finding 1）が
    /// フォルダブックの request 時 stat に同じロジックを再利用するため。
    public static func statFile(_ path: String) -> (Int64?, Double?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return (nil, nil) }
        let size = (attrs[.size] as? Int64) ?? (attrs[.size] as? NSNumber)?.int64Value
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        return (size, mtime)
    }

    public func updateBookTitle(id: Int, newTitle: String) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET title = ? WHERE id = ?",
                arguments: [TextNormalize.nfc(newTitle), id]
            )
        }
    }

    public func updateBookPages(id: Int, newPages: Int) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET pages = ? WHERE id = ?",
                arguments: [newPages, id]
            )
        }
    }

    /// Updates the cover_crop_rect (JSON or NULL) for the given book.
    public func updateBookCoverCropRect(id: Int, json: String?) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET cover_crop_rect = ? WHERE id = ?",
                arguments: [json, id]
            )
        }
    }

    // MARK: - Finder tag sync baseline (Phase G39)
    //
    // 「前回同期した Finder タグ」を `book.finder_tags_synced` に `MultiValueParser` の
    // `", "` 区切りで持つ。単純な合併では削除が伝わらない（どちらで消しても片方に残った
    // ままなので復活してしまう）ため、3 方向マージ（Task 7）が「前回」と比較して初めて
    // 削除を検出できる。
    //
    // NULL と `""`（空文字列）は意味が違う:
    //   - NULL  … この本はまだ一度も Finder タグと同期していない（3 方向マージで
    //             baseline として扱わない = 「今回が初回なので何も削除しない」）
    //   - `""`  … 前回同期はしたが、その時点でタグが 0 件だった（baseline = 空集合。
    //             今回どちらかにタグが増えていれば正しく追加として扱われる）
    // この区別を保つため `finderTagBaseline` は `String?` を返し、
    // `setFinderTagBaseline` は `String?` を受け取る（呼び出し側が nil/"" を明示的に選ぶ）。

    /// 指定した本の「前回同期した Finder タグ」を返す。列が NULL（未同期）なら nil。
    public func finderTagBaseline(bookID: Int) throws -> String? {
        guard let q = queue else { return nil }
        return try q.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT finder_tags_synced FROM book WHERE id = ?",
                arguments: [bookID]
            )
        }
    }

    /// 指定した本の「前回同期した Finder タグ」を設定する。
    /// `value: nil` は「未同期」に戻す（通常は同期の度に非 nil を書くので、明示的なリセット用）。
    /// `value: ""` は「同期済みだが 0 件だった」を表す。
    public func setFinderTagBaseline(bookID: Int, value: String?) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET finder_tags_synced = ? WHERE id = ?",
                arguments: [value, bookID]
            )
        }
    }

    /// 全ての本の「前回同期した Finder タグ」を 1 クエリでまとめて返す。
    ///
    /// **`finderTagBaseline(bookID:)` を 12,000 冊分ループしてはいけない**（実測 約 2.8 秒。
    /// spec §7 の「12,000 冊の庫を開いても体感で待たされない」を満たせない）。同期の入口で
    /// 一度だけ呼ぶ。
    ///
    /// **NULL（未同期）の本はキーごと含めない。**`nil`（未同期）と `""`（同期済みだが 0 件）の
    /// 区別は消してはならず（この区別が「今回が初回なので何も削除しない」を決める）、
    /// 辞書では「キーが無い = NULL」で表す。
    public func finderTagBaselines() throws -> [Int: String] {
        guard let q = queue else { return [:] }
        return try q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, finder_tags_synced FROM book WHERE finder_tags_synced IS NOT NULL"
            )
            var out: [Int: String] = [:]
            out.reserveCapacity(rows.count)
            for row in rows {
                out[row["id"]] = row["finder_tags_synced"]
            }
            return out
        }
    }

    /// 複数の本の「前回同期した Finder タグ」を**1 トランザクション**で書く。
    ///
    /// 1 冊ずつ `setFinderTagBaseline` を呼ぶと 12,000 冊で約 6.8 秒（実測）。
    /// 書くのは**値が変わった本だけ**にすること（呼び出し側の責務）。
    public func setFinderTagBaselines(_ values: [Int: String]) throws {
        guard let q = queue, !values.isEmpty else { return }
        try q.write { db in
            // 文をキャッシュして使い回す（毎回 `execute(sql:)` すると 12,000 冊で
            // コンパイルのコストが効いてくる）。
            let stmt = try db.cachedStatement(
                sql: "UPDATE book SET finder_tags_synced = ? WHERE id = ?")
            for (id, value) in values {
                try stmt.execute(arguments: [value, id])
            }
        }
    }

    /// 全ての本の「前回同期した Finder タグ」を NULL（未同期）に戻す。
    ///
    /// **呼び出し責務**: `library_settings.finderTagSyncField` が変わったとき（Task 7）に
    /// 呼ぶ。前回値を残したまま項目を切り替えると、別項目の値を「前回のタグ」と誤認し、
    /// 3 方向マージが実在しない削除を検出して**大量にタグを消しかねない**。
    public func clearAllFinderTagBaselines() throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET finder_tags_synced = NULL")
        }
    }

    public func fetchAllPlaylistKinds() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM playlist ORDER BY id")
        }
    }

    /// Fetch all shelves (playlists) ordered by title. Includes all kinds.
    public func fetchAllShelves() throws -> [PlaylistRow] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, kind, icon, item_view, tool_tab,
                       (conditions IS NOT NULL) AS is_smart
                FROM playlist
                ORDER BY title
                """)
                .map { row in
                    PlaylistRow(
                        id: row["id"] as Int64,
                        title: row["title"] as String,
                        kind: row["kind"] as String,
                        icon: row["icon"] as Int?,
                        itemView: (row["item_view"] as Int) != 0,
                        toolTab: (row["tool_tab"] as Int) != 0,
                        isSmart: (row["is_smart"] as Int) != 0
                    )
                }
        }
    }

    public func fetchPlaylistBookCount(playlistID: Int64) throws -> Int {
        guard let q = queue else { return 0 }
        return try q.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist_item WHERE playlist_id = ?",
                arguments: [playlistID]
            ) ?? 0
        }
    }

    /// Idempotently creates a 'favorites' kind playlist if missing. Returns its id.
    public func ensureFavoritesShelf() throws -> Int64 {
        guard let q = queue else {
            throw ImportError.databaseNotOpen
        }
        return try q.write { db in
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM playlist WHERE kind = 'favorites' LIMIT 1"
            ) {
                return existing
            }
            try db.execute(
                sql: """
                INSERT INTO playlist (title, type, icon, item_view, tool_tab, conditions, kind)
                VALUES (?, ?, NULL, 0, 0, NULL, 'favorites')
                """,
                arguments: ["お気に入り", 0]
            )
            return db.lastInsertedRowID
        }
    }

    /// Create a new user-kind shelf with the given title. Returns the new id.
    public func createUserShelf(title: String) throws -> Int64 {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        return try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO playlist (title, type, icon, item_view, tool_tab, conditions, kind)
                VALUES (?, ?, NULL, 0, 0, NULL, 'user')
                """,
                arguments: [title, 0]
            )
            return db.lastInsertedRowID
        }
    }

    /// スマートシェルフを新規作成（kind='user', conditions=JSON）。type は 0 固定（判定に不使用）。
    public func createSmartShelf(title: String, conditions: SmartShelfConditions) throws -> Int64 {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        let blob = try JSONEncoder().encode(conditions)
        return try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO playlist (title, type, icon, item_view, tool_tab, conditions, kind)
                VALUES (?, 0, NULL, 0, 0, ?, 'user')
                """,
                arguments: [title, blob])
            return db.lastInsertedRowID
        }
    }

    /// スマートシェルフの条件を更新。
    public func updateSmartShelfConditions(id: Int64, conditions: SmartShelfConditions) throws {
        guard let q = queue else { return }
        let blob = try JSONEncoder().encode(conditions)
        try q.write { db in
            try db.execute(sql: "UPDATE playlist SET conditions = ? WHERE id = ?", arguments: [blob, id])
        }
    }

    /// conditions BLOB を読み出し、新モデル優先・旧 PlaylistConditions フォールバックでデコード。
    public func fetchSmartShelfConditions(id: Int64) throws -> SmartShelfConditions? {
        guard let q = queue else { return nil }
        let blob: Data? = try q.read { db in
            try Data.fetchOne(db, sql: "SELECT conditions FROM playlist WHERE id = ?", arguments: [id])
        }
        guard let data = blob else { return nil }
        if let modern = try? JSONDecoder().decode(SmartShelfConditions.self, from: data) {
            return modern
        }
        if let legacy = try? JSONDecoder().decode(PlaylistConditions.self, from: data) {
            return LegacyConditionsConverter.convert(legacy)
        }
        return nil
    }

    /// Rename an existing shelf.
    public func renameShelf(id: Int64, title: String) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE playlist SET title = ? WHERE id = ?",
                arguments: [title, id]
            )
        }
    }

    /// Delete a shelf. playlist_item rows cascade automatically via FK ON DELETE CASCADE.
    public func deleteShelf(id: Int64) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
        }
    }

    /// Appends books to a shelf, skipping any IDs already present (idempotent dedup).
    public func appendBooksToShelf(playlistID: Int64, bookIDs: [Int]) throws {
        guard let q = queue else { return }
        try q.write { db in
            // Fetch existing book IDs in this shelf
            let existing = try Set(Int.fetchAll(
                db,
                sql: "SELECT book_id FROM playlist_item WHERE playlist_id = ?",
                arguments: [playlistID]
            ))
            let newIDs = bookIDs.filter { !existing.contains($0) }
            guard !newIDs.isEmpty else { return }

            // Find next position (COALESCE handles empty shelf → starts at 0)
            let maxPos = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) FROM playlist_item WHERE playlist_id = ?",
                arguments: [playlistID]
            ) ?? -1

            for (offset, bookID) in newIDs.enumerated() {
                try db.execute(
                    sql: Tables.insertPlaylistItemSQL,
                    arguments: [playlistID, bookID, maxPos + 1 + offset]
                )
            }
        }
    }

    /// Remove a single book from a shelf.
    public func removeBookFromShelf(playlistID: Int64, bookID: Int) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_item WHERE playlist_id = ? AND book_id = ?",
                arguments: [playlistID, bookID]
            )
        }
    }

    /// Remove multiple books from a shelf in a single write transaction.
    public func removeBooksFromShelf(playlistID: Int64, bookIDs: [Int]) throws {
        guard let q = queue else { return }
        guard !bookIDs.isEmpty else { return }
        try q.write { db in
            for bookID in bookIDs {
                try db.execute(
                    sql: "DELETE FROM playlist_item WHERE playlist_id = ? AND book_id = ?",
                    arguments: [playlistID, bookID]
                )
            }
        }
    }

    /// Fetch all books in a given playlist, ordered by playlist_item.position.
    public func fetchBooksInPlaylist(playlistID: Int64) throws -> [BookRow] {
        guard let q = queue else { return [] }
        return try q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.bookColumnsB)
                FROM book b
                INNER JOIN playlist_item pi ON pi.book_id = b.id
                WHERE pi.playlist_id = ?
                ORDER BY pi.position ASC
                """, arguments: [playlistID])
            return rows.map { Self.bookRow(from: $0) }
        }
    }

    /// Builds a SQL WHERE-clause fragment from a FilterState. The returned SQL
    /// always starts with " AND " (or empty string if no filter is active),
    /// so callers can append it after their primary WHERE condition.
    /// `now` is injectable for test determinism.
    public static func buildFilterClause(
        _ filter: FilterState,
        now: Date = Date()
    ) -> (whereSQL: String, args: [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !filter.bookTypes.isEmpty {
            let placeholders = filter.bookTypes.map { _ in "?" }.joined(separator: ",")
            clauses.append("b.book_type IN (\(placeholders))")
            args.append(contentsOf: filter.bookTypes.sorted().map { $0 as DatabaseValueConvertible })
        }
        if let mode = filter.unseen {
            clauses.append("b.unseen = ?")
            args.append(mode == .unreadOnly ? 1 : 0)
        }
        if let min = filter.ratingMin {
            if min == 0 {
                clauses.append("b.rating = 0")
            } else {
                clauses.append("b.rating >= ?")
                args.append(min)
            }
        }
        if let range = filter.dateAdded {
            appendDateClause(&clauses, &args, column: "b.date_added", range: range, now: now)
        }
        if let range = filter.playDate {
            appendDateClause(&clauses, &args, column: "b.play_date", range: range, now: now)
        }

        // Text facet filters with multi-value partial match (LIKE 4-pattern)
        let textFields: [(Set<String>, String)] = [
            (filter.genres,    "b.genre"),
            (filter.serieses,  "b.series"),
            (filter.authors,   "b.author"),
            (filter.netas,     "b.neta"),
            (filter.keywordAs, "b.keyword_a"),
            (filter.keywordBs, "b.keyword_b"),
            (filter.keywordCs, "b.keyword_c"),
        ]
        for (values, column) in textFields {
            guard !values.isEmpty else { continue }
            appendTextFacetClause(&clauses, &args, column: column, values: values)
        }

        let whereSQL = clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND ")
        return (whereSQL, args)
    }

    /// Appends a text-facet clause for one column, handling multi-value ", "-delimited stored values.
    /// Each filter value generates 4 LIKE patterns:
    ///   exact match, leading "value, %", middle "%, value, %", trailing "%, value"
    /// Multiple filter values are OR-combined inside a single parenthesised group.
    private static func appendTextFacetClause(
        _ clauses: inout [String],
        _ args: inout [DatabaseValueConvertible],
        column: String,
        values: Set<String>
    ) {
        var perValue: [String] = []
        for value in values.sorted() {
            let (sql, newArgs) = multiValueClauseForOneValue(column: column, value: value)
            perValue.append(sql)
            args.append(contentsOf: newArgs.map { $0 as DatabaseValueConvertible })
        }
        clauses.append("(\(perValue.joined(separator: " OR ")))")
    }

    /// Builds a LIKE 4-pattern clause for one value against one column.
    /// Returns (clauseSQL, args) where args has 4 entries: [exact, leading, middle, trailing].
    static func multiValueClauseForOneValue(column: String, value: String) -> (String, [String]) {
        let escaped = escapeLikePattern(value)
        let esc = "ESCAPE '\\'"
        let clause = """
            (\(column) = ? \
            OR \(column) LIKE ? \(esc) \
            OR \(column) LIKE ? \(esc) \
            OR \(column) LIKE ? \(esc))
            """
        let args = [
            value,
            "\(escaped), %",
            "%, \(escaped), %",
            "%, \(escaped)",
        ]
        return (clause, args)
    }

    private static func appendDateClause(
        _ clauses: inout [String],
        _ args: inout [DatabaseValueConvertible],
        column: String,
        range: FilterState.DateRangeCondition,
        now: Date
    ) {
        let cutoff = now.timeIntervalSince1970 - Double(range.days) * Self.secondsPerDay
        switch range.direction {
        case .within:
            clauses.append("\(column) >= ?")
        case .olderThan:
            clauses.append("\(column) < ?")
        }
        args.append(cutoff)
    }

    /// LIKE pattern 用の escape helper。`%` `_` `\` をバックスラッシュで escape する。
    /// SQL 側で `ESCAPE '\'` 句と組み合わせて使う。Phase 2.4e (FTS5 trigram + LIKE fallback)の
    /// LIKE fallback に加え、facet filter（テキストフィールドの部分一致）でも使う。
    static func escapeLikePattern(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%",  with: "\\%")
         .replacingOccurrences(of: "_",  with: "\\_")
    }

    /// 1-2 文字検索の LIKE fallback 用 WHERE 句ビルダ。FTS と同一の 7 列 (title / author /
    /// genre / keyword_a / keyword_b / neta / memo) を OR で連結し、ESCAPE 句で安全に。
    /// 戻り値の whereSQL は `(b.title LIKE ? ESCAPE '\\' OR ...)` の形 (先頭 AND なし)。
    /// 呼び出し側で他の WHERE 条件と AND 連結する。Phase 2.4e。
    public static func buildLikeClause(
        _ pattern: String
    ) -> (whereSQL: String, args: [DatabaseValueConvertible]) {
        let cols = ["b.title", "b.author", "b.genre", "b.keyword_a", "b.keyword_b", "b.neta", "b.memo"]
        let clauses = cols.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
        let whereSQL = "(\(clauses))"
        let args: [DatabaseValueConvertible] = Array(repeating: pattern, count: cols.count)
        return (whereSQL, args)
    }

    /// Browser pane の上位列 selection を SQL WHERE に変換するヘルパ。
    /// Phase 2.4d-browser-pane で追加。constraints は [(SQL カラム名, 値)] のタプル配列、
    /// 整数カラム (rating / book_type) は Int として bind、それ以外は String として bind。
    public static func buildBrowserClause(
        _ constraints: [(column: String, value: String)]
    ) throws -> (whereSQL: String, args: [DatabaseValueConvertible]) {
        guard !constraints.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for (rawCol, value) in constraints {
            let col = try validatedColumn(rawCol, allowed: browseColumns)
            if multiValueColumns.contains(col) {
                // multi-value columns use 4-pattern LIKE matching (exact / leading / middle / trailing)
                let (clause, likeArgs) = multiValueClauseForOneValue(column: "b.\(col)", value: value)
                clauses.append(clause)
                args.append(contentsOf: likeArgs.map { $0 as DatabaseValueConvertible })
            } else {
                clauses.append("b.\(col) = ?")
                if (col == "rating" || col == "book_type"), let intVal = Int(value) {
                    args.append(intVal)
                } else {
                    args.append(value)
                }
            }
        }
        let whereSQL = " AND " + clauses.joined(separator: " AND ")
        return (whereSQL, args)
    }

    /// text 系マルチ値カラム (genre / author / neta / keyword_a/b/c) は DB の生値を
    /// Swift 側で split + unique + sorted に変換する。integer カラムはそのまま返す。
    private static let multiValueColumns: Set<String> = [
        "genre", "author", "neta", "keyword_a", "keyword_b", "keyword_c"
    ]

    /// SQL DISTINCT で取得した生配列をマルチ値カラム向けに dedup/sort する。
    /// - integer カラム: そのまま返す。
    /// - text カラム: 各要素をカンマ split → 全 token を順序維持で dedup → sorted。
    private static func dedupeMultiValue(_ rawValues: [String], column: String) -> [String] {
        guard multiValueColumns.contains(column) else { return rawValues }
        var seen: Set<String> = []
        var result: [String] = []
        for raw in rawValues {
            for token in MultiValueParser.split(raw) {
                if seen.insert(token).inserted {
                    result.append(token)
                }
            }
        }
        return result.sorted()
    }

    /// `distinctValues` / `searchBooks` が共有する検索経路。クエリ長で 3 通りに分かれ、
    /// FTS 経路だけが仮想表 `book_fts` の JOIN を伴う。
    private enum SearchPath {
        /// 空クエリ。検索述語なし。
        case all
        /// 1-2 文字の LIKE fallback（trigram FTS は 3 文字以上を要求するため）。Phase 2.4e。
        case like(whereSQL: String, args: [DatabaseValueConvertible])
        /// 3 文字以上の trigram FTS。
        case fts(query: String)
    }

    /// 検索経路 × sidebar scope から組み立てた SQL 断片。
    private struct ScopedQuery {
        /// `FROM book b` に続く JOIN 群（先頭に改行付き、無ければ空文字）。
        let joins: String
        /// `WHERE` に続く述語。必ず `1=1` で始まるので、述語が 1 つも無くても文法が壊れない。
        let whereSQL: String
        /// `whereSQL` 中の `?` と同順の bind 値。
        let args: [DatabaseValueConvertible]
    }

    /// クエリ文字列から検索経路を決める（空 / 1-2 文字 LIKE / 3 文字以上 trigram FTS）。
    private static func searchPath(for trimmed: String) -> SearchPath {
        if trimmed.isEmpty { return .all }
        if trimmed.count < 3 {
            let (whereSQL, args) = buildLikeClause("%\(escapeLikePattern(trimmed))%")
            return .like(whereSQL: whereSQL, args: args)
        }
        // trigram は default で部分一致するため wildcard 不要。`"` だけ FTS 構文用に escape する。
        return .fts(query: "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\"")
    }

    /// 検索経路 × scope の直積で同型に散らばっていた JOIN / WHERE / bind 値を 1 か所で組む。
    ///
    /// 述語の並びは `検索 → scope → スマートシェルフ → filter → browser → recent 日付` に統一した。
    /// 元コードは経路ごとに並びが揺れていた（LIKE × shelf のみ `pi.playlist_id` が LIKE の前）が、
    /// AND の連言なので順序は結果に影響しない。bind 値は必ず SQL 中の `?` と同順で積むこと。
    private static func scopedQuery(
        path: SearchPath,
        scope: SidebarScope,
        smart: (whereSQL: String, args: [DatabaseValueConvertible]),
        filterClause: (whereSQL: String, args: [DatabaseValueConvertible]),
        browserClause: (whereSQL: String, args: [DatabaseValueConvertible])
    ) -> ScopedQuery {
        var joins: [String] = []
        var whereSQL = "1=1"
        var args: [DatabaseValueConvertible] = []

        switch path {
        case .all:
            break
        case .like(let likeSQL, let likeArgs):
            whereSQL += " AND \(likeSQL)"
            args.append(contentsOf: likeArgs)
        case .fts(let query):
            joins.append("INNER JOIN book_fts ON book_fts.rowid = b.id")
            whereSQL += " AND book_fts MATCH ?"
            args.append(query)
        }

        // recent の日付述語だけは filter/browser の後ろに置く（元 SQL と同じ位置）。
        var recentCutoff: Double?
        switch scope {
        case .library, .smartShelf:
            // スマートシェルフ条件。`.smartShelf` 以外は ("", []) なので SQL に影響しない。
            whereSQL += smart.whereSQL
            args.append(contentsOf: smart.args)
        case .favorites(let pid), .shelf(let pid):
            joins.append("INNER JOIN playlist_item pi ON pi.book_id = b.id")
            whereSQL += " AND pi.playlist_id = ?"
            args.append(pid)
        case .recent(let days):
            recentCutoff = Date().timeIntervalSince1970 - Double(days) * secondsPerDay
        }

        whereSQL += filterClause.whereSQL
        args.append(contentsOf: filterClause.args)
        whereSQL += browserClause.whereSQL
        args.append(contentsOf: browserClause.args)

        if let cutoff = recentCutoff {
            whereSQL += " AND b.date_added >= ?"
            args.append(cutoff)
        }

        return ScopedQuery(
            joins: joins.isEmpty ? "" : "\n" + joins.joined(separator: "\n"),
            whereSQL: whereSQL,
            args: args
        )
    }

    /// `searchBooks` の ORDER BY。scope が優先（shelf は手動並び順、recent は追加日の新しい順）で、
    /// library / smartShelf のときだけ検索経路で決まる（FTS は関連度 rank、それ以外は id 順）。
    private static func bookOrderBy(path: SearchPath, scope: SidebarScope) -> String {
        switch scope {
        case .favorites, .shelf:
            return "pi.position ASC"
        case .recent:
            return "b.date_added DESC"
        case .library, .smartShelf:
            if case .fts = path { return "rank" }
            return "b.id"
        }
    }

    /// Browser pane の各列に表示する distinct 値のリストを返す。
    /// scope/filter/searchQuery/上位列の selection を全て AND 連結して絞り込んだ範囲で DISTINCT する。
    /// NULL は除外、ORDER BY value ASC で安定順序。
    /// 整数カラム (rating / book_type) も String にキャストして返す (UI 側で表示文字列に変換)。
    /// text 系マルチ値カラムは Swift 側で split + unique + sorted に後処理する。
    public func distinctValues(
        forColumn column: String,
        query: String,
        sidebarScope: SidebarScope,
        filter: FilterState = FilterState(),
        browserConstraints: [(column: String, value: String)] = []
    ) throws -> [String] {
        guard let q = queue else { return [] }
        let column = try Self.validatedColumn(column, allowed: Self.browseColumns)
        let browserClause = try Self.buildBrowserClause(browserConstraints)
        // 検索経路（空 / LIKE / FTS）と scope（library・smartShelf / favorites・shelf / recent）の
        // 直積を 1 か所で組む。scope 別のスマートシェルフ条件・JOIN・日付述語も scopedQuery が持つ。
        let scoped = Self.scopedQuery(
            path: Self.searchPath(for: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            scope: sidebarScope,
            smart: smartClauseForScope(sidebarScope),
            filterClause: Self.buildFilterClause(filter),
            browserClause: browserClause
        )

        // ★不変条件（`AND b.<col> IS NOT NULL` を **末尾**に置いているため必須）:
        //   `scoped.whereSQL` に載る各断片は、**内部に OR を含むなら自身を括弧で包む**こと。
        //   裸の OR を返す断片が 1 つでもあると `A AND (B OR C) AND D` のつもりが
        //   `(A AND B) OR (C AND D)` に化け、**ブラウザペインに scope 外の値が黙って混ざる**
        //   （クラッシュもエラーも出ないので気づけない）。
        //   現在の生成元 4 つ（buildLikeClause / appendTextFacetClause / buildBrowserClause /
        //   SmartShelfClause）はいずれも括弧で包む。断片を足すときはここを守ること。
        //
        // SQL DISTINCT で rawValues を取得し、text 系マルチ値カラムのみ Swift 側で split + unique + sorted。
        let rawValues = try q.read { db in
            let sql = """
                SELECT DISTINCT CAST(b.\(column) AS TEXT) AS v
                FROM book b\(scoped.joins)
                WHERE \(scoped.whereSQL) AND b.\(column) IS NOT NULL
                ORDER BY v
                """
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(scoped.args))
        }
        // text 系マルチ値カラムのみ split + unique + sorted を後適用
        return Self.dedupeMultiValue(rawValues, column: column)
    }

    /// `#<id>` 形式の検索クエリから book id を抽出する。
    /// AppCore の `SearchQueryParser.bookID(from:)` と同一ロジック。
    /// LibraryStore は AppCore に依存できない（AppCore→LibraryStore の既存依存と循環するため）ため、
    /// ここに private static helper として複製している。ロジック変更時は両方を同期すること。
    private static func bookIDFromSearch(_ query: String) -> Int? {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#") else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(rest)
    }

    /// Full-text search via FTS5. Empty query returns all books for the scope.
    public func searchBooks(
        query: String,
        sidebarScope: SidebarScope,
        filter: FilterState = FilterState(),
        browserConstraints: [(column: String, value: String)] = [],
        limit: Int? = nil
    ) throws -> [BookRow] {
        guard let q = queue else { return [] }
        // G13: 検索欄 `#<id>` は book ID 完全一致(ライブラリ全体・scope/filter 無視)。
        // ローカル list もサーバ BooksQuery も本関数に委譲するため、ここ1箇所で両方に効く。
        if let bid = Self.bookIDFromSearch(query) {
            return (try fetchBook(id: bid)).map { [$0] } ?? []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query + filter/browser inactive → fast path (existing helpers).
        // `.smartShelf` は条件評価のため fast path を使わず動的 SQL に進む。
        if trimmed.isEmpty && filter.isEmpty && browserConstraints.isEmpty {
            switch sidebarScope {
            case .library: return try fetchAllBooks()
            case .favorites(let id), .shelf(let id): return try fetchBooksInPlaylist(playlistID: id)
            case .recent(let days): return try fetchRecentBooks(days: days)
            case .smartShelf: break   // fall through to dynamic SQL below
            }
        }

        // 検索経路（空 / LIKE / FTS）と scope の直積を 1 か所で組む（`distinctValues` と共有）。
        let browserClause = try Self.buildBrowserClause(browserConstraints)
        let path = Self.searchPath(for: trimmed)
        let scoped = Self.scopedQuery(
            path: path,
            scope: sidebarScope,
            smart: smartClauseForScope(sidebarScope),
            filterClause: Self.buildFilterClause(filter),
            browserClause: browserClause
        )
        let limitClause = limit.map { "LIMIT \($0)" } ?? ""

        return try q.read { db in
            let sql = """
                SELECT \(Self.bookColumnsB)
                FROM book b\(scoped.joins)
                WHERE \(scoped.whereSQL)
                ORDER BY \(Self.bookOrderBy(path: path, scope: sidebarScope))
                \(limitClause)
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(scoped.args))
            return rows.map { Self.bookRow(from: $0) }
        }
    }

    // MARK: - library_settings

    /// Returns the value for the given key, or nil if the key does not exist.
    public func getLibrarySetting(key: String) throws -> String? {
        guard let q = queue else { return nil }
        return try q.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM library_settings WHERE key = ?", arguments: [key])
        }
    }

    /// Inserts or updates the value for the given key (UPSERT semantics).
    /// G25c: 複数の設定キーを**単一の read transaction**で読む。
    ///
    /// 書き込みを原子的にしても読みが分割されていると意味がない。salt と hash を別々に読むと、
    /// その間に別接続が原子的に (S2, H2) へ差し替えた場合に `H1 + S2` のような**世代混在**を掴み、
    /// 新旧どちらのパスワードでも照合できない状態になる。組で読む。
    /// - Returns: 存在したキーのみを含む辞書（欠けているキーは省かれる）。
    public func getLibrarySettings(keys: [String]) throws -> [String: String] {
        guard let q = queue, !keys.isEmpty else { return [:] }
        return try q.read { db in
            var out: [String: String] = [:]
            for key in keys {
                if let v = try String.fetchOne(db, sql: "SELECT value FROM library_settings WHERE key = ?",
                                               arguments: [key]) {
                    out[key] = v
                }
            }
            return out
        }
    }

    /// G25c: 複数の設定キーを**単一トランザクション**で書く。
    ///
    /// ロックの salt と hash のように**組で意味を持つ値**を別々のトランザクションで書くと、
    /// 同時実行や外部からの変更と交錯して `salt B + hash A` のような不整合が残り、
    /// **どのパスワードでも解錠できない庫**になりうる。組は必ずまとめて書く。
    public func setLibrarySettings(_ pairs: [String: String]) throws {
        guard let q = queue, !pairs.isEmpty else { return }
        try q.write { db in
            for (key, value) in pairs {
                try db.execute(
                    sql: "INSERT INTO library_settings (key, value) VALUES (?, ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
        }
    }

    /// G25c: 複数の設定キーを**単一トランザクション**で削除する（施錠解除で salt/hash を同時に消す用）。
    public func deleteLibrarySettings(keys: [String]) throws {
        guard let q = queue, !keys.isEmpty else { return }
        try q.write { db in
            for key in keys {
                try db.execute(sql: "DELETE FROM library_settings WHERE key = ?", arguments: [key])
            }
        }
    }

    /// G25c: 期待値と一致するときだけ更新する原子的 compare-and-set。更新できたら true。
    ///
    /// #8 の遅延ハッシュ移行（旧 SHA-256 / 旧 iteration → 現行 PBKDF2）は「検証したハッシュが**今も DB 上の値**」
    /// のときだけ書き戻さなければならない。メモリ上の値と比較する方式では、別プロセス／別 Mac が
    /// DB を書き換えていた場合を検出できず、**外部が設定した新しいパスワードを旧パスワード由来の
    /// ハッシュで巻き戻す**（ロックのダウングレード）。単一の UPDATE ... WHERE で判定と書き込みを
    /// 不可分にし、更新行数で結果を返す。
    ///
    /// キーが存在しない場合は false（行がヒットしないため）。INSERT はしない
    /// ＝「消えている（施錠解除済み）」を「一致しない」として扱うのが安全側。
    public func compareAndSetLibrarySetting(key: String, expected: String, newValue: String) throws -> Bool {
        guard let q = queue else { return false }
        return try q.write { db in
            try db.execute(
                sql: "UPDATE library_settings SET value = ? WHERE key = ? AND value = ?",
                arguments: [newValue, key, expected]
            )
            return db.changesCount == 1
        }
    }

    /// G27a task 8 (Codex High #1): 複数キーを**単一トランザクション**で、`conditionKey` の
    /// 現在値を条件とした compare-and-set で書く。ロックの salt+hash のように「pair 全体を
    /// 新値に差し替えるが、整合性の判定は hash 1 本で行う」ケース向け。
    ///
    /// 読み（現在値の確認）と書き（新値の INSERT/UPDATE）を `queue.write` の**同一トランザクション**
    /// 内で行うため、確認と書き込みの間に他の書き込みが割り込む隙が無い（compareAndSetLibrarySetting
    /// と同じ不可分性）。
    /// - `expectedValue` が `nil` の場合は「`conditionKey` がまだ存在しない」ことを条件にする
    ///   （新規作成時の race 防止 — 二重の同時「新規施錠」がどちらも無検証で通ってしまうのを防ぐ）。
    /// - Returns: 条件が一致し実際に書けたか。不一致なら false（DB は一切変更されない）。
    public func compareAndSetLibrarySettings(conditionKey: String, expectedValue: String?,
                                             newValues: [String: String]) throws -> Bool {
        guard let q = queue, !newValues.isEmpty else { return false }
        return try q.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT value FROM library_settings WHERE key = ?", arguments: [conditionKey])
            guard current == expectedValue else { return false }
            for (key, value) in newValues {
                try db.execute(
                    sql: "INSERT INTO library_settings (key, value) VALUES (?, ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
            return true
        }
    }

    /// 上記の削除版。`conditionKey` の現在値が `expectedValue` と一致するときだけ
    /// `keysToDelete` を全て単一トランザクションで削除する。
    /// - Returns: 条件が一致し実際に削除したか。不一致なら false（DB は一切変更されない）。
    public func compareAndDeleteLibrarySettings(conditionKey: String, expectedValue: String,
                                                keysToDelete: [String]) throws -> Bool {
        guard let q = queue, !keysToDelete.isEmpty else { return false }
        return try q.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT value FROM library_settings WHERE key = ?", arguments: [conditionKey])
            guard current == expectedValue else { return false }
            for key in keysToDelete {
                try db.execute(sql: "DELETE FROM library_settings WHERE key = ?", arguments: [key])
            }
            return true
        }
    }

    public func setLibrarySetting(key: String, value: String) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO library_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    /// Removes the value for the given key. No-op if the key does not exist.
    public func deleteLibrarySetting(key: String) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "DELETE FROM library_settings WHERE key = ?", arguments: [key])
        }
    }

    /// Restores a BookRow with its original id (Undo/redo path). Uses a plain INSERT
    /// (NOT "INSERT OR REPLACE"): `book.id` is `INTEGER PRIMARY KEY` without AUTOINCREMENT,
    /// so a freed id can be reused by a later import/add. If restore used OR REPLACE, it
    /// would silently overwrite that unrelated new book. Plain INSERT instead throws a
    /// SQLite UNIQUE constraint error on such a collision; callers must treat that as
    /// "target id occupied — skip this row" rather than fail the whole batch (see
    /// LibraryServerCore `POST books/restore`, and `DeleteBooksCommand.undo` for local).
    public func restoreBook(_ row: BookRow) throws {
        try insertBook(row, replace: false)
    }

    /// Inserts a BookRow directly (test/internal use). Production paths typically use insertBook(BookRecord).
    /// `replace: true` (default) preserves legacy INSERT OR REPLACE semantics used by direct
    /// BookRow insertion in tests/fixtures. `replace: false` is used by `restoreBook` so an id
    /// collision surfaces as a thrown error instead of silently clobbering an unrelated row.
    func insertBook(_ row: BookRow, replace: Bool = true) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: replace ? Tables.insertBookSQL : Tables.insertBookPlainSQL,
                arguments: [
                    row.id,
                    TextNormalize.nfcValue(row.title),
                    TextNormalize.nfcValue(row.author),
                    TextNormalize.nfcValue(row.genre),
                    row.path,                        // path: do NOT normalize (filesystem ref)
                    row.dateAdded.timeIntervalSince1970,
                    row.playDate?.timeIntervalSince1970,
                    row.bookType, row.fileType, row.pages, row.rating,
                    row.unseen ? 1 : 0,
                    TextNormalize.nfcValue(row.keywordA),
                    TextNormalize.nfcValue(row.keywordB),
                    TextNormalize.nfcValue(row.keywordC),
                    TextNormalize.nfcValue(row.neta),
                    TextNormalize.nfcValue(row.memo),
                    TextNormalize.nfcValue(row.series),
                    row.volume,
                    row.coverImageName,              // coverImageName: do NOT normalize (FS ref)
                    row.coverCropRect.map { BookRow.encodeCoverCropRect($0) },   // cover_crop_rect (JSON string / nil)
                    row.pageDirection?.rawValue,                                 // page_direction ("rightToLeft"/"leftToRight" / nil)
                    row.contentHash,                                             // content_hash
                    row.fileSize,                                                // file_size
                    row.fileMtime,                                               // file_mtime
                ]
            )
        }
    }

    // MARK: - Patch-based updates

    /// Bound parameters derived from a BookPatch, ready to plug into updateBookSQL.
    /// Throws BookPatchError.emptyTitle if patch.title is non-nil but empty/whitespace.
    private struct PatchBindings {
        let trimmedTitle: String?
        let author: String?
        let keywordA: String?
        let keywordB: String?
        let keywordC: String?
        let genre: String?
        let neta: String?
        let memo: String?
        let clampedRating: Int?
        let unseenInt: Int?
        let clampedType: Int?
        let series: String?
        let volume: Double?
        let coverImageName: String?
        // Fix 2.5c-a: explicit NULL clear flags for series/volume
        let clearSeries: Bool
        let clearVolume: Bool
        // Task 3 spec 2.5c-b: explicit NULL clear flag for cover_image_name
        let clearCoverImageName: Bool
        // Phase 2.6b-2 D1: per-book page direction
        let pageDirection: PageDirection?
        let clearPageDirection: Bool
    }

    /// Normalizes a multi-value field string via split → join round-trip.
    /// Ensures values are always stored with `, ` separator regardless of how
    /// the user typed them (e.g. "A,B" without spaces → "A, B").
    /// Returns nil if the input is nil; returns the normalized string otherwise.
    private static func normalizeMultiValue(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let parts = MultiValueParser.split(raw)
        return parts.isEmpty ? raw : MultiValueParser.join(parts)
    }

    /// Validates a patch and produces the SQL bindings.
    /// Title is trimmed and rejected if empty. Rating/bookType are clamped to 0...5.
    /// Multi-value text fields (author/genre/keywordA/B/C/neta) are normalized via
    /// split → join round-trip so they always use `, ` separator in the DB.
    private func validatedBindings(for patch: BookPatch) throws -> PatchBindings {
        let trimmedTitle: String?
        if let t = patch.title {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw BookPatchError.emptyTitle
            }
            trimmedTitle = TextNormalize.nfc(trimmed)
        } else {
            trimmedTitle = nil
        }
        return PatchBindings(
            trimmedTitle: trimmedTitle,
            author: Self.normalizeMultiValue(patch.author).map { TextNormalize.nfc($0) },
            keywordA: Self.normalizeMultiValue(patch.keywordA).map { TextNormalize.nfc($0) },
            keywordB: Self.normalizeMultiValue(patch.keywordB).map { TextNormalize.nfc($0) },
            keywordC: Self.normalizeMultiValue(patch.keywordC).map { TextNormalize.nfc($0) },
            genre: Self.normalizeMultiValue(patch.genre).map { TextNormalize.nfc($0) },
            neta: Self.normalizeMultiValue(patch.neta).map { TextNormalize.nfc($0) },
            memo: TextNormalize.nfc(patch.memo),
            clampedRating: patch.rating.map { max(0, min(5, $0)) },
            unseenInt: patch.unseen.map { $0 ? 1 : 0 },
            clampedType: patch.bookType.map { max(0, min(5, $0)) },
            series: TextNormalize.nfc(patch.series),
            volume: patch.volume,
            coverImageName: patch.coverImageName,   // coverImageName: do NOT normalize (FS ref)
            clearSeries: patch.clearSeries,
            clearVolume: patch.clearVolume,
            clearCoverImageName: patch.clearCoverImageName,
            pageDirection: patch.pageDirection,
            clearPageDirection: patch.clearPageDirection
        )
    }

    /// Builds the StatementArguments array for updateBookSQL given pre-validated bindings + book id.
    /// series/volume/cover_image_name/page_direction use CASE WHEN: (clearFlag, value) pairs.
    private static func updateArguments(_ b: PatchBindings, bookID: Int) -> [DatabaseValueConvertible?] {
        return [
            b.trimmedTitle,
            b.author,
            b.keywordA,
            b.keywordB,
            b.keywordC,
            b.genre,
            b.neta,
            b.memo,
            b.clampedRating,
            b.unseenInt,
            b.clampedType,
            b.clearSeries ? 1 : nil as Int?,             // CASE WHEN ? THEN NULL
            b.series,                                      // ELSE COALESCE(?, series)
            b.clearVolume ? 1 : nil as Int?,              // CASE WHEN ? THEN NULL
            b.volume,                                      // ELSE COALESCE(?, volume)
            b.clearCoverImageName ? 1 : nil as Int?,      // CASE WHEN ? THEN NULL
            b.coverImageName,                              // ELSE COALESCE(?, cover_image_name)
            b.clearPageDirection ? 1 : nil as Int?,       // CASE WHEN ? THEN NULL
            b.pageDirection?.rawValue,                     // ELSE COALESCE(?, page_direction)
            bookID,
        ]
    }

    /// Validates and applies a patch to a single book.
    /// Title (when non-nil) is trimmed and rejected if empty/whitespace-only.
    /// Rating and bookType are clamped to valid ranges (0-5).
    public func updateBook(id: Int, patch: BookPatch) throws {
        if patch.isEmpty { return }
        let bindings = try validatedBindings(for: patch)
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: Tables.updateBookSQL,
                arguments: StatementArguments(Self.updateArguments(bindings, bookID: id))
            )
        }
    }

    /// Bulk update — applies the same patch to all given IDs in one transaction.
    /// Validation rules match `updateBook(id:patch:)`. No-op when ids or patch is empty.
    public func updateBooks(ids: [Int], patch: BookPatch) throws {
        if ids.isEmpty || patch.isEmpty { return }
        let bindings = try validatedBindings(for: patch)
        guard let q = queue else { return }
        try q.write { db in
            for id in ids {
                try db.execute(
                    sql: Tables.updateBookSQL,
                    arguments: StatementArguments(Self.updateArguments(bindings, bookID: id))
                )
            }
        }
    }

    // MARK: - Book metadata mutators

    public func setRating(bookID: Int, rating: Int) throws {
        let clamped = max(0, min(5, rating))
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET rating = ? WHERE id = ?", arguments: [clamped, bookID])
        }
    }

    public func setRating(bookIDs: [Int], rating: Int) throws {
        guard !bookIDs.isEmpty, let q = queue else { return }
        let clamped = max(0, min(5, rating))
        try q.write { db in
            let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = [clamped]
            args.append(contentsOf: bookIDs)
            try db.execute(
                sql: "UPDATE book SET rating = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    public func setUnread(bookID: Int, unread: Bool) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET unseen = ? WHERE id = ?", arguments: [unread ? 1 : 0, bookID])
        }
    }

    /// Mark a book as read by setting unseen=false AND updating play_date to the
    /// supplied timestamp. Matches Stackroom behavior on viewer-launch / mark-read.
    public func markAsRead(bookID: Int, at date: Date) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET unseen = 0, play_date = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, bookID]
            )
        }
    }

    public func setUnread(bookIDs: [Int], unread: Bool) throws {
        guard !bookIDs.isEmpty, let q = queue else { return }
        try q.write { db in
            let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = [unread ? 1 : 0]
            args.append(contentsOf: bookIDs)
            try db.execute(
                sql: "UPDATE book SET unseen = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    public func setBookType(bookID: Int, type: Int) throws {
        let clamped = max(0, min(5, type))
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET book_type = ? WHERE id = ?", arguments: [clamped, bookID])
        }
    }

    public func setBookType(bookIDs: [Int], type: Int) throws {
        guard !bookIDs.isEmpty, let q = queue else { return }
        let clamped = max(0, min(5, type))
        try q.write { db in
            let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = [clamped]
            args.append(contentsOf: bookIDs)
            try db.execute(
                sql: "UPDATE book SET book_type = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Series distinct values

    /// book.series の DISTINCT 値を大文字小文字を無視した順序で取得。NULL と空文字は除外。
    public func fetchDistinctSeriesValues() throws -> [String] {
        guard let q = queue else { return [] }
        return try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT series FROM book
                WHERE series IS NOT NULL AND series != ''
                ORDER BY series COLLATE NOCASE
                """)
        }
    }

    // MARK: - Direct queue access for testing

    /// Executes a closure in a write transaction. Used primarily by tests.
    public func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        return try q.write(block)
    }

    /// Executes a closure in a read transaction. Used primarily by tests.
    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        return try q.read(block)
    }

    /// Executes raw SQL in a write transaction (test use only — bypasses NFC normalization).
    func rawExecuteForTest(_ sql: String, _ args: [DatabaseValueConvertible?] = []) throws {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        try q.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Runs the NFC backfill migration on all existing book rows (test hook).
    func runNFCBackfillForTest() throws {
        guard let q = queue else { throw ImportError.databaseNotOpen }
        try q.write { db in
            try Migration.normalizeAllBookTextToNFC(db: db)
        }
    }

    // MARK: - Phase 2.6b-2: per-book viewer state

    /// Loads the per-book viewer state. Returns defaults (spread off, cover offset
    /// on, last page 0, no overrides) when no row exists.
    public func loadViewerState(bookID: Int) throws -> StoredViewerState {
        guard let q = queue else { return StoredViewerState() }
        return try q.read { db in
            var state = StoredViewerState()
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT spread_enabled, cover_offset, last_page, spread_explicit FROM book_viewer_state WHERE book_id = ?",
                arguments: [bookID]
            ) {
                let spreadInt: Int = row["spread_enabled"]
                let coverInt: Int = row["cover_offset"]
                let explicitInt: Int = row["spread_explicit"]
                state.spreadEnabled = spreadInt != 0
                state.coverOffset = coverInt != 0
                state.lastPage = row["last_page"]
                // Phase 2.6b-2 T5: 行が存在する場合のみ true。App 層が spread デフォルト解決に使用。
                state.hasPersistedState = true
                // G17 T6a: spread_enabled がユーザー明示操作由来かどうか（progress-only 行と区別）。
                state.spreadExplicit = explicitInt != 0
            }
            let overrideRows = try Row.fetchAll(
                db,
                sql: "SELECT page_index, mode FROM book_page_layout WHERE book_id = ?",
                arguments: [bookID]
            )
            var overrides: [Int: Int] = [:]
            for r in overrideRows {
                let page: Int = r["page_index"]
                let mode: Int = r["mode"]
                overrides[page] = mode
            }
            state.overrides = overrides
            return state
        }
    }

    /// 全 book の閲覧進行状況（last_page / updated_at）の一括取得結果 1 件分
    /// （Phase 4.1a: LibraryServer の books 一覧 DTO 用）。
    public struct ViewerProgress: Sendable, Equatable {
        public let lastPage: Int
        public let updatedAt: Date?
        public init(lastPage: Int, updatedAt: Date?) {
            self.lastPage = lastPage
            self.updatedAt = updatedAt
        }
    }

    /// 全 book の閲覧状態（last_page / updated_at）を一括取得する。
    /// 行が存在する本だけが結果に含まれる。`updated_at` は epoch 秒の TEXT
    /// （`saveViewerState` の刻印形式）を Date に復号し、不正値は nil。
    public func fetchAllViewerStates() throws -> [Int: ViewerProgress] {
        guard let q = queue else { return [:] }
        return try q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT book_id, last_page, updated_at FROM book_viewer_state"
            )
            var out: [Int: ViewerProgress] = [:]
            for row in rows {
                let updated: Date? = (row["updated_at"] as String?)
                    .flatMap { Double($0) }
                    .map { Date(timeIntervalSince1970: $0) }
                out[row["book_id"]] = ViewerProgress(lastPage: row["last_page"], updatedAt: updated)
            }
            return out
        }
    }

    /// Upserts the per-book viewer flags + reading position. Does not touch overrides.
    /// `updated_at` is stamped as the epoch seconds string (matches how the rest of
    /// the codebase stores time as REAL epoch; here stored as TEXT per schema).
    /// This is the native, user-explicit save path (e.g. 'd' key toggle) — it always
    /// stamps `spread_explicit = 1` (G17 T6a) so `AppState.resolvedState` can trust
    /// `spreadEnabled` instead of falling back to `spreadByDefault`.
    public func saveViewerState(bookID: Int, spreadEnabled: Bool, coverOffset: Bool, lastPage: Int) throws {
        guard let q = queue else { return }
        let stamp = String(Date().timeIntervalSince1970)
        try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO book_viewer_state (book_id, spread_enabled, cover_offset, last_page, updated_at, spread_explicit)
                VALUES (?, ?, ?, ?, ?, 1)
                ON CONFLICT(book_id) DO UPDATE SET
                    spread_enabled  = excluded.spread_enabled,
                    cover_offset    = excluded.cover_offset,
                    last_page       = excluded.last_page,
                    updated_at      = excluded.updated_at,
                    spread_explicit = 1
                """,
                arguments: [bookID, spreadEnabled ? 1 : 0, coverOffset ? 1 : 0, lastPage, stamp]
            )
        }
    }

    /// last_page / updated_at のみ更新する（Phase 4.1a: リモート progress 書き込み用）。
    /// spread_enabled / cover_offset / spread_explicit の既存値は保持し、行が無い本には
    /// テーブルの DEFAULT 値（Tables.swift v13/v17: spread_enabled=0, spread_explicit=0）で
    /// INSERT する。spread_explicit を 0 のままにすることで、Web リーダーの progress
    /// writeback だけで作られた行を「ユーザーが明示的に単ページ設定した」と誤認しない
    /// （G17 T6a: `AppState.resolvedState` はこの行を spreadByDefault にフォールバックする）。
    public func updateLastPage(bookID: Int, lastPage: Int) throws {
        guard let q = queue else { return }
        let stamp = String(Date().timeIntervalSince1970)
        try q.write { db in
            try db.execute(
                sql: """
                INSERT INTO book_viewer_state (book_id, last_page, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(book_id) DO UPDATE SET
                    last_page  = excluded.last_page,
                    updated_at = excluded.updated_at
                """,
                arguments: [bookID, lastPage, stamp]
            )
        }
    }

    /// 本のページ方向を更新する（Web リーダーからの書き戻し用）。nil で「未設定（既定に従う）」に戻す。
    public func updatePageDirection(bookID: Int, direction: PageDirection?) throws {
        guard let q = queue else { return }
        try q.write { db in
            try db.execute(
                sql: "UPDATE book SET page_direction = ? WHERE id = ?",
                arguments: [direction?.rawValue, bookID]
            )
        }
    }

    /// Sets or clears a per-page layout override. `mode == nil` deletes the row
    /// (= back to auto). Otherwise upserts the raw mode int (0 = forcePair, 1 = forceSolo).
    public func setPageOverride(bookID: Int, page: Int, mode: Int?) throws {
        guard let q = queue else { return }
        try q.write { db in
            if let mode {
                try db.execute(
                    sql: """
                    INSERT INTO book_page_layout (book_id, page_index, mode)
                    VALUES (?, ?, ?)
                    ON CONFLICT(book_id, page_index) DO UPDATE SET mode = excluded.mode
                    """,
                    arguments: [bookID, page, mode]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM book_page_layout WHERE book_id = ? AND page_index = ?",
                    arguments: [bookID, page]
                )
            }
        }
    }

    /// The next volume in the same series (strictly higher `volume`). Returns nil when
    /// the current book has no series / no volume, or when there is no higher volume.
    /// Ordered by volume ASC then id ASC (stable tiebreak).
    public func nextVolumeInSeries(after book: BookRow) throws -> BookRow? {
        guard let series = book.series, !series.isEmpty, let vol = book.volume else { return nil }
        guard let q = queue else { return nil }
        return try q.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.bookColumns)
                FROM book
                WHERE series = ? AND series != '' AND volume IS NOT NULL AND volume > ?
                ORDER BY volume ASC, id ASC
                LIMIT 1
                """,
                arguments: [series, vol]
            )
            return row.map(Self.bookRow(from:))
        }
    }

    /// The previous volume in the same series (strictly lower `volume`). Returns nil
    /// when the current book has no series / no volume, or when there is no lower
    /// volume. Ordered by volume DESC then id DESC (stable tiebreak).
    public func prevVolumeInSeries(before book: BookRow) throws -> BookRow? {
        guard let series = book.series, !series.isEmpty, let vol = book.volume else { return nil }
        guard let q = queue else { return nil }
        return try q.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.bookColumns)
                FROM book
                WHERE series = ? AND series != '' AND volume IS NOT NULL AND volume < ?
                ORDER BY volume DESC, id DESC
                LIMIT 1
                """,
                arguments: [series, vol]
            )
            return row.map(Self.bookRow(from:))
        }
    }

    public func close() {
        queueLock.lock()
        _queue = nil
        queueLock.unlock()
        isOpen = false
    }
}
