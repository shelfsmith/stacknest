// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("book_integrity store (G27a)")
struct IntegrityStoreTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    /// `pages` 以外は固定の最小 BookRow。`BookRow.init` は memo までが必須。
    private func book(id: Int, title: String, path: String?, pages: Int?) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: pages,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    private func record(bookID: Int, status: IntegrityStatus, checkedAt: Int64,
                        method: IntegrityMethod = .quick,
                        entryCount: Int? = nil, badEntries: [String] = []) -> IntegrityRecord {
        IntegrityRecord(bookID: bookID, status: status, method: method, checkedAt: checkedAt,
                        fileSize: nil, fileMtime: nil, entryCount: entryCount,
                        badEntries: badEntries, prevStatus: nil, prevCheckedAt: nil)
    }

    @Test("書いた内容がそのまま読み戻せる")
    func upsertAndFetchRoundTrip() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 1_700_000_000,
            fileSize: 123, fileMtime: 456.0, entryCount: 10, badEntries: ["005.png"],
            prevStatus: nil, prevCheckedAt: nil))

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .damaged)
        #expect(got.method == .quick)
        #expect(got.checkedAt == 1_700_000_000)
        #expect(got.fileSize == 123)
        #expect(got.entryCount == 10)
        #expect(got.badEntries == ["005.png"])
    }

    @Test("2 回目の upsert で 1 回目の結果が prev_* に退避される")
    func upsertCarriesPreviousGeneration() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 200))

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .damaged)
        #expect(got.prevStatus == .ok, "1 世代前が退避されていない")
        #expect(got.prevCheckedAt == 100)
        #expect(got.isDegraded, "ok → damaged は劣化として扱う")
    }

    @Test("3 回目でも保持されるのは直前の 1 世代だけ")
    func upsertKeepsOnlyOneGeneration() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .empty, checkedAt: 200))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 300))

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.prevStatus == .empty)
        #expect(got.prevCheckedAt == 200)
        #expect(got.isDegraded == false, "直前が empty なので劣化ではない")
    }

    // MARK: - G27b Codex 2nd review Fix1/2: 原子的な「既存行が無ければ書く」

    /// full スキャンが評価できないカテゴリ（folder/video/text）専用の atomic insert。
    /// 素直な「既存行が無ければ新規に書く」の基本ケース。
    @Test("insertIntegrityIfAbsent: 既存行が無ければ新規に書き true を返す")
    func insertIfAbsentInsertsWhenNoExistingRow() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.mp4", pages: nil))

        let inserted = try db.insertIntegrityIfAbsent(
            record(bookID: 1, status: .unsupported, checkedAt: 100, method: .full))
        #expect(inserted == true)

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .unsupported)
        #expect(got.method == .full)
        #expect(got.checkedAt == 100)
    }

    /// 本命: 既存行がある（quick スキャンが damaged を付けた）場合は一切変更せず false を返す。
    /// これが Fix1/2 の直接の回帰テスト ―― 修正前の「読んでから書く」2 段階実装だと、
    /// この単一メソッド自体は存在せず（folder だけが手書きの read-then-write でこの規律を
    /// 再現していた）、video/text は本テストが検証する不変条件を一切守れていなかった。
    @Test("insertIntegrityIfAbsent: 既存行があれば一切変更せず false を返す")
    func insertIfAbsentNoOpsWhenExistingRowPresent() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.mp4", pages: nil))
        try db.upsertIntegrity(IntegrityRecord(
            bookID: 1, status: .damaged, method: .quick, checkedAt: 100,
            fileSize: nil, fileMtime: nil, entryCount: nil,
            badEntries: ["enumeration truncated"], prevStatus: nil, prevCheckedAt: nil))

        let inserted = try db.insertIntegrityIfAbsent(
            record(bookID: 1, status: .unsupported, checkedAt: 999, method: .full))
        #expect(inserted == false, "既存行があるのに挿入できたことになっている")

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .damaged, "既存の damaged が unsupported に書き換わっている")
        #expect(got.method == .quick, "method が更新されている＝何か書いてしまっている")
        #expect(got.checkedAt == 100, "checked_at が更新されている＝何か書いてしまっている")
    }

    /// 原子性そのものの検証。単一の INSERT OR IGNORE 文で完結するため、複数の呼び出しを
    /// 同時に投げても「片方だけが勝ち、負けた側は相手の行に一切触らない」という結果にしか
    /// なりえない（read-then-write なら、両方が「行が無い」を読んでから両方が書こうとする
    /// 窓ができ、片方の判定がもう片方の insert で消される可能性がある）。
    /// GRDB の DatabaseQueue は書き込みを直列化するため真の同時実行は起きないが、
    /// 「複数回呼んでも 1 回しか挿入は成功せず、成立した行の値がどちらか一方のものと
    /// 完全に一致し続ける（中間状態が存在しない）」ことを検証する。
    @Test("insertIntegrityIfAbsent: 並行呼び出しでも挿入は 1 回だけ成立する")
    func insertIfAbsentIsAtomicUnderConcurrentCallers() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.mp4", pages: nil))

        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try db.insertIntegrityIfAbsent(IntegrityRecord(
                        bookID: 1, status: .unsupported, method: .full,
                        checkedAt: Int64(i), fileSize: nil, fileMtime: nil,
                        entryCount: nil, badEntries: [],
                        prevStatus: nil, prevCheckedAt: nil))
                }
            }
            var collected: [Bool] = []
            for try await r in group { collected.append(r) }
            return collected
        }

        #expect(results.filter { $0 }.count == 1, "挿入に成功したのは 1 回だけであるべき")
        // 最終状態は「勝った 1 回」の checked_at のどれかと完全一致する（中間状態が無い）。
        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect((0..<8).contains(Int(got.checkedAt)))
        #expect(got.status == .unsupported)
        #expect(got.method == .full)
    }

    @Test("summary が検査済/未検査/破損/劣化を数える")
    func summaryCounts() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/tmp/a.zip", pages: nil))
        try db.insertBook(book(id: 2, title: "b", path: "/tmp/b.zip", pages: nil))
        try db.insertBook(book(id: 3, title: "c", path: "/tmp/c.zip", pages: nil))

        // 1 は ok → damaged（劣化）、2 は damaged 一度きり、3 は未検査。
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 200))
        try db.upsertIntegrity(record(bookID: 2, status: .damaged, checkedAt: 200))

        let s = try db.integritySummary()
        #expect(s.checked == 2)
        #expect(s.unchecked == 1)
        #expect(s.damaged == 2)
        #expect(s.degraded == 1, "劣化は 1 のみ（2 は前回が無いので劣化ではない）")
    }

    @Test("status を指定して本と結果を一覧できる")
    func listByStatus() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "broken", path: "/tmp/a.zip", pages: nil))
        try db.insertBook(book(id: 2, title: "fine", path: "/tmp/b.zip", pages: nil))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 1, entryCount: 3,
                                      badEntries: ["009.jpg"]))
        try db.upsertIntegrity(record(bookID: 2, status: .ok, checkedAt: 1))

        let damaged = try db.integrityRecords(status: .damaged)
        #expect(damaged.count == 1)
        #expect(damaged.first?.0.title == "broken")
        #expect(damaged.first?.1.badEntries == ["009.jpg"])
    }

    @Test("簡易チェックの候補は pages が NULL か 0 の本だけ")
    func booksNeedingQuickCheckSelectsNullOrZeroPages() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "null", path: "/tmp/a.zip", pages: nil))
        try db.insertBook(book(id: 2, title: "zero", path: "/tmp/b.zip", pages: 0))
        try db.insertBook(book(id: 3, title: "done", path: "/tmp/c.zip", pages: 12))

        let ids = Set(try db.booksNeedingQuickCheck().map(\.id))
        #expect(ids == [1, 2])
    }

    @Test("最終検査時刻は book_integrity 全体の checked_at 最大値")
    func lastCheckedAtIsMaxAcrossAllRows() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/tmp/a.zip", pages: nil))
        try db.insertBook(book(id: 2, title: "b", path: "/tmp/b.zip", pages: nil))

        #expect(try db.integrityLastCheckedAt() == nil, "1 件も無ければ nil")

        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        #expect(try db.integrityLastCheckedAt() == 100)

        try db.upsertIntegrity(record(bookID: 2, status: .damaged, checkedAt: 300))
        #expect(try db.integrityLastCheckedAt() == 300, "damaged の行も対象に含む（status を問わない）")

        // 1 の再検査で checked_at が更新されても、まだ 2 の 300 の方が新しい。
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 150))
        #expect(try db.integrityLastCheckedAt() == 300)
    }

    @Test("bad_entries は上限で切り詰められる")
    func badEntriesAreCapped() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))
        let many = (0..<100).map { "e\($0).jpg" }
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 1, badEntries: many))

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.badEntries.count == IntegrityRecord.maxBadEntries)
    }

    @Test("ライブラリが閉じられていると upsertIntegrity は throw する(Fix5)")
    func upsertIntegrityThrowsWhenLibraryClosed() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))
        db.close()

        #expect(throws: DatabaseError.self) {
            try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 1))
        }
    }

    @Test("ライブラリが閉じられていると updateBookFileStat は throw する(Fix5)")
    func updateBookFileStatThrowsWhenLibraryClosed() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))
        db.close()

        #expect(throws: DatabaseError.self) {
            try db.updateBookFileStat(id: 1, size: 100, mtime: 1.0)
        }
    }

    // MARK: - G27b 最終レビュー Fix1: 同じ結果の再検査で劣化証跡が消えないこと

    @Test("ok→damaged→damaged と再検査しても劣化(isDegraded)は残る")
    func rechckingSameDamagedStatusKeepsDegradedEvidence() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        // 1 回目: ok。2 回目: damaged（ここで劣化が成立＝prev_status='ok'）。
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 200))
        var got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.isDegraded, "前提: ここで劣化が成立していること")

        // 3 回目: 「破損のみ再検査」相当。まだ damaged のまま ―― 同じ status への再検査で
        // prev_status が damaged に上書きされ、劣化の証跡が消えてはいけない。
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 300))
        got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .damaged)
        #expect(got.prevStatus == .ok, "同じ status への再検査で prev_status が上書きされている")
        #expect(got.prevCheckedAt == 100)
        #expect(got.isDegraded, "劣化の証跡が再検査で消えてしまっている")
        #expect(got.checkedAt == 300, "checked_at 自体は通常どおり更新される")

        let s = try db.integritySummary()
        #expect(s.degraded == 1, "summary の劣化件数も再検査で 0 に落ちてはいけない")
    }

    @Test("ok→ok→damaged は通常どおり劣化として検出される")
    func repeatedOkThenDamagedStillDetectsDegradation() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 200))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 300))

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .damaged)
        #expect(got.prevStatus == .ok, "直前の ok が退避されているべき")
        #expect(got.prevCheckedAt == 200)
        #expect(got.isDegraded)
    }

    @Test("damaged→ok は従来どおり劣化フラグをクリアする")
    func damagedThenOkClearsDegradedAsBefore() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))

        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, checkedAt: 200))
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 300))   // 修復後の再検査

        let got = try #require(try db.integrityRecord(bookID: 1))
        #expect(got.status == .ok)
        #expect(got.prevStatus == .damaged)
        #expect(got.isDegraded == false, "修復後は劣化フラグがクリアされる（従来どおり）")

        let s = try db.integritySummary()
        #expect(s.degraded == 0)
    }

    @Test("migrate を 2 回呼んでも壊れない（冪等）")
    func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.insertBook(book(id: 1, title: "t", path: "/tmp/x.zip", pages: nil))
        try db.upsertIntegrity(record(bookID: 1, status: .ok, checkedAt: 1))
        #expect(try db.integrityRecord(bookID: 1) != nil)
    }
}
