// SPDX-License-Identifier: MIT
import Foundation
import GRDB

extension Database {
    /// 検査結果を 1 冊分書く。
    ///
    /// **既存行があれば、その status / checked_at を prev_* に退避してから上書きする。**
    /// 呼び出し側は prev_* を詰めなくてよい。1 世代だけ保持する。
    public func upsertIntegrity(_ record: IntegrityRecord) throws {
        guard let q = queue else { return }
        let badJSON = (try? JSONEncoder().encode(record.badEntries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try q.write { db in
            let existing = try Row.fetchOne(
                db, sql: "SELECT status, checked_at FROM book_integrity WHERE book_id = ?",
                arguments: [record.bookID])
            let prevStatus: String? = existing?["status"]
            let prevCheckedAt: Int64? = existing?["checked_at"]
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
