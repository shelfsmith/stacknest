// SPDX-License-Identifier: MIT
import Foundation
import GRDB

extension Database {
    /// 検査結果を 1 冊分書く。
    ///
    /// **既存行があれば、その status / checked_at を prev_* に退避してから上書きする —
    /// ただし今回の status が前回と同じ（変化なし）ときは退避しない。**
    /// 呼び出し側は prev_* を詰めなくてよい。1 世代だけ保持する。
    ///
    /// G27b 最終レビュー Fix1（Critical）: 「変化なし」でも無条件に prev_* を今回値で
    /// 上書きしていたため、`ok → damaged`（劣化検出）の直後に damaged のまま再検査すると
    /// `prev_status` が `damaged` に置き換わり `isDegraded`（`prev_status == .ok`）が偽になって
    /// しまっていた。「破損のみ再検査」（修復確認）や `--mode all` の連続実行は日常的に起こる
    /// 操作であり、そのたびに劣化の証跡（唯一のビット腐敗の記録）が消えるのは 31 時間規模の
    /// 全件スキャンの存在意義そのものを損なう。既存行の status が今回と同じであれば、
    /// prev_status/prev_checked_at は既存値のまま温存する（checked_at 等それ以外は通常どおり更新）。
    public func upsertIntegrity(_ record: IntegrityRecord) throws {
        // Fix5: この 2 メソッドは G27a で新設されたもの。黙って return すると、走査の
        // 途中でライブラリが閉じられても呼び出し側（QuickIntegrityScanner）は成功したと
        // 誤認し `persistenceFailures: 0` のまま何も書けていない結果を返してしまう。
        // 既存の updateBookPages 等（他フェーズ由来の同種ガード）はスコープ外＝据え置き。
        guard let q = queue else { throw DatabaseError.libraryClosed }
        let badJSON = (try? JSONEncoder().encode(record.badEntries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try q.write { db in
            let existing = try Row.fetchOne(
                db, sql: "SELECT status, checked_at, prev_status, prev_checked_at FROM book_integrity WHERE book_id = ?",
                arguments: [record.bookID])
            let existingStatus: String? = existing?["status"]
            // Fix1: status が変化していない（同じ結果の再検査）なら、既存の prev_* をそのまま
            // 引き継ぐ。変化した（今回はじめて今の status になった）ときだけ、直前の状態を
            // prev_* へ退避する ―― これが従来どおりの「1 世代だけ保持する」挙動。
            let prevStatus: String?
            let prevCheckedAt: Int64?
            if existingStatus == record.status.rawValue {
                prevStatus = existing?["prev_status"]
                prevCheckedAt = existing?["prev_checked_at"]
            } else {
                prevStatus = existingStatus
                prevCheckedAt = existing?["checked_at"]
            }
            try db.execute(sql: """
                INSERT INTO book_integrity
                    (book_id, status, method, checked_at, file_size, file_mtime,
                     entry_count, bad_entries, prev_status, prev_checked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(book_id) DO UPDATE SET
                    status = excluded.status,
                    method = excluded.method,
                    checked_at = excluded.checked_at,
                    file_size = excluded.file_size,
                    file_mtime = excluded.file_mtime,
                    entry_count = excluded.entry_count,
                    bad_entries = excluded.bad_entries,
                    prev_status = excluded.prev_status,
                    prev_checked_at = excluded.prev_checked_at
                """,
                arguments: [record.bookID, record.status.rawValue, record.method.rawValue,
                            record.checkedAt, record.fileSize, record.fileMtime,
                            record.entryCount, badJSON, prevStatus, prevCheckedAt])
        }
    }

    /// G27b Codex 2nd review Fix1/2: `folder`/`video`/`text` のように full スキャンが実際には
    /// 評価できないカテゴリ専用の、**原子的**な「既存行が無ければ書く」。
    ///
    /// 旧実装（folder のみ）は「`integrityRecord(bookID:)` で既存行の有無を読む」→
    /// 「無ければ `upsertIntegrity` で書く」の 2 トランザクションに分かれており、その間に
    /// G27a の quick スキャンエンドポイント（同期・`MaintenanceJobRegistry` を経由しないため
    /// 1 ライブラリ 1 ジョブのガードの対象外）が同じ本に `damaged` を書き込める窓
    /// （TOCTOU）があった ―― full スキャンの `unsupported` insert がそれを消してしまう。
    /// ライブラリロックの compare-and-set 化（`compareAndSetLibrarySetting`）と同じ規律で、
    /// 判定と書き込みを単一の `INSERT OR IGNORE` 文に閉じ込め、読んでから書くまでの窓を無くす。
    ///
    /// 戻り値: 実際に新規挿入したら true。既存行があり何もしなかったら false
    /// （呼び出し側はこれを見て byStatus 等の集計に含めるかを判断する）。
    public func insertIntegrityIfAbsent(_ record: IntegrityRecord) throws -> Bool {
        guard let q = queue else { throw DatabaseError.libraryClosed }
        let badJSON = (try? JSONEncoder().encode(record.badEntries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return try q.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO book_integrity
                    (book_id, status, method, checked_at, file_size, file_mtime,
                     entry_count, bad_entries, prev_status, prev_checked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [record.bookID, record.status.rawValue, record.method.rawValue,
                            record.checkedAt, record.fileSize, record.fileMtime,
                            record.entryCount, badJSON, record.prevStatus?.rawValue,
                            record.prevCheckedAt])
            return db.changesCount == 1
        }
    }

    public func integrityRecord(bookID: Int) throws -> IntegrityRecord? {
        guard let q = queue else { return nil }
        return try q.read { (db) -> IntegrityRecord? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM book_integrity WHERE book_id = ?", arguments: [bookID])
            else { return nil }
            return Self.decodeIntegrity(row, bookID: bookID)
        }
    }

    /// 検査済/未検査/破損/劣化の件数。
    public func integritySummary() throws -> IntegritySummary {
        guard let q = queue else {
            return IntegritySummary(checked: 0, unchecked: 0, damaged: 0, degraded: 0)
        }
        return try q.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book") ?? 0
            let checked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_integrity") ?? 0
            let damaged = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM book_integrity WHERE status = 'damaged'") ?? 0
            let degraded = try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM book_integrity
                    WHERE status = 'damaged' AND prev_status = 'ok'
                    """) ?? 0
            return IntegritySummary(checked: checked, unchecked: max(0, total - checked),
                                    damaged: damaged, degraded: degraded)
        }
    }

    /// 直近の検査時刻（`book_integrity` 全体の `checked_at` 最大値）。1 件も無ければ nil。
    ///
    /// G27b Task 6: 整合性チェックウィンドウの「最終検査」表示用。`integrityRecords(status:)` は
    /// status ごとに `fetchBook(id:)` を N 回呼ぶため全 status を走査してここに使うと 5,000 件規模で
    /// N+1 になる。ここは集計のみの単発クエリで、件数に関わらず軽量。
    public func integrityLastCheckedAt() throws -> Int64? {
        guard let q = queue else { return nil }
        return try q.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(checked_at) FROM book_integrity")
        }
    }

    /// 指定 status の本と検査結果を返す（一覧用）。
    public func integrityRecords(status: IntegrityStatus) throws -> [(BookRow, IntegrityRecord)] {
        guard let q = queue else { return [] }
        let ids: [Int] = try q.read { db in
            try Int.fetchAll(db, sql: "SELECT book_id FROM book_integrity WHERE status = ?",
                             arguments: [status.rawValue])
        }
        // BookRow の組み立ては既存の fetchBook(id:) に委ねる（Row からの独自デコードを増やさない）。
        return try ids.compactMap { id in
            guard let book = try fetchBook(id: id),
                  let rec = try integrityRecord(bookID: id) else { return nil }
            return (book, rec)
        }.sorted { $0.0.title < $1.0.title }
    }

    /// 簡易チェックの候補＝`pages` が未取得の本（spec §4.2）。
    public func booksNeedingQuickCheck() throws -> [BookRow] {
        guard let q = queue else { return [] }
        let ids: [Int] = try q.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM book WHERE pages IS NULL OR pages = 0 ORDER BY id")
        }
        return try ids.compactMap { try fetchBook(id: $0) }
    }

    /// 詳細スキャン（CRC 検証）の候補（spec §4.3・Phase G27b）。
    ///
    /// **カテゴリ（アーカイブ/フォルダ/画像/動画/テキスト）でフィルタしない** ―― 判定には
    /// `FileManager` での実 I/O（ディレクトリかどうか）が要るため、SQL 側では行えない
    /// （`booksNeedingQuickCheck` が同じ理由でフィルタしないのと同じ判断）。判定は
    /// `FullIntegrityScanner` が担い、アーカイブ以外は `unsupported` として書き戻すことで
    /// 次回以降の `.uncheckedOnly` から外れる（brief にある「書かないと毎回対象に残る」の対策）。
    public func booksNeedingFullCheck(mode: FullScanMode) throws -> [BookRow] {
        guard let q = queue else { return [] }
        let ids: [Int] = try q.read { db in
            switch mode {
            case .uncheckedOnly:
                // method='full' の行が「無い」本 ―― method='quick' の行しか無い本（G27a の
                // 簡易チェック済み）も、full 行が無い限りここに含まれる（この区別を落とすと
                // 全件が対象外になる。brief が名指しした落とし穴）。
                return try Int.fetchAll(db, sql: """
                    SELECT book.id FROM book
                    WHERE NOT EXISTS (
                        SELECT 1 FROM book_integrity
                        WHERE book_integrity.book_id = book.id AND book_integrity.method = 'full'
                    )
                    ORDER BY book.id
                    """)
            case .all:
                // 既存の book_integrity 行を完全に無視する ―― ビット腐敗検出の唯一の手段
                // （file_size/file_mtime は劣化を検出できないため、spec §4.1 の「全件やり直し」）。
                return try Int.fetchAll(db, sql: "SELECT id FROM book ORDER BY id")
            case .damagedOnly:
                // 直近の status が damaged の本。method（quick/full どちらで damaged になったか）
                // は問わない ―― brief の「status='damaged' の本」という文言のとおり。
                return try Int.fetchAll(db, sql: """
                    SELECT book.id FROM book
                    JOIN book_integrity ON book_integrity.book_id = book.id
                    WHERE book_integrity.status = 'damaged'
                    ORDER BY book.id
                    """)
            }
        }
        return try ids.compactMap { try fetchBook(id: $0) }
    }

    /// 検査時に取れた stat を書き戻す（G27a ④。実機では 99.5% が NULL のままだった）。
    /// `pages` の書き戻しは既存の `updateBookPages(id:newPages:)`（Database.swift）を再利用する。
    public func updateBookFileStat(id: Int, size: Int64, mtime: Double) throws {
        // Fix5: 上の upsertIntegrity と同じ理由で throw する（scope: この 2 メソッドのみ）。
        guard let q = queue else { throw DatabaseError.libraryClosed }
        try q.write { db in
            try db.execute(sql: "UPDATE book SET file_size = ?, file_mtime = ? WHERE id = ?",
                           arguments: [size, mtime, id])
        }
    }

    private static func decodeIntegrity(_ row: Row, bookID: Int) -> IntegrityRecord {
        let statusRaw: String? = row["status"]
        let methodRaw: String? = row["method"]
        let prevRaw: String? = row["prev_status"]
        let badJSON: String? = row["bad_entries"]
        return IntegrityRecord(
            bookID: bookID,
            status: statusRaw.flatMap(IntegrityStatus.init(rawValue:)) ?? .unsupported,
            method: methodRaw.flatMap(IntegrityMethod.init(rawValue:)) ?? .quick,
            checkedAt: row["checked_at"] ?? 0,
            fileSize: row["file_size"], fileMtime: row["file_mtime"],
            entryCount: row["entry_count"],
            badEntries: decodeBadEntries(badJSON),
            prevStatus: prevRaw.flatMap(IntegrityStatus.init(rawValue:)),
            prevCheckedAt: row["prev_checked_at"])
    }

    private static func decodeBadEntries(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
