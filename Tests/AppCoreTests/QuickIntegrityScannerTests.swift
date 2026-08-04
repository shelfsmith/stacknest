// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import ArchiveAdapter

@Suite("quick integrity scan (G27a)")
struct QuickIntegrityScannerTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func book(id: Int, title: String, path: String, pages: Int? = nil) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: pages,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    /// 既定は「存在するアーカイブ・24 ページ・stat 成功」。個別テストで必要な所だけ差し替える。
    private func deps(probe: @escaping @Sendable (URL) async -> QuickProbe,
                      statFile: @escaping @Sendable (String) -> (Int64?, Double?) = { _ in (4096, 111.0) },
                      fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
                      now: @escaping @Sendable () -> Int64 = { 1_700_000_000 })
    -> QuickIntegrityScanner.Dependencies {
        QuickIntegrityScanner.Dependencies(
            categoryOf: { _ in .archive }, fileExists: fileExists,
            statFile: statFile, probe: probe, now: now)
    }

    @Test("正常な本は ok が記録され pages と file_size が書き戻される(②+④)")
    func okBookPersistsStatusAndBackfills() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 24, truncated: false) }))

        #expect(report.scanned == 1)
        #expect(report.byStatus[.ok] == 1)
        #expect(report.pagesUpdated == 1)

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .ok)
        #expect(rec.method == .quick)
        #expect(rec.entryCount == 24)
        #expect(rec.fileSize == 4096)
        #expect(rec.checkedAt == 1_700_000_000)

        let updated = try #require(try db.fetchBook(id: 1))
        #expect(updated.pages == 24, "pages が書き戻されていない")
        #expect(updated.fileSize == 4096, "file_size が書き戻されていない")
    }

    @Test("破損本は damaged が記録され pages は書き戻されない")
    func damagedBookDoesNotBackfillPages() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "b", path: "/lib/b.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 13, truncated: true) }))

        #expect(report.byStatus[.damaged] == 1)
        #expect(report.pagesUpdated == 0)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .damaged)
        #expect(try #require(db.fetchBook(id: 1)).pages == nil, "破損本の pages を確定させてはいけない")
    }

    @Test("ファイル不在は missing が記録され、開こうとしない")
    func missingFileIsRecordedWithoutProbing() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "c", path: "/lib/gone.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { _ in
                Issue.record("不在ファイルを開こうとした")
                return .failed(reason: "unreachable")
            },
            statFile: { _ in (nil, nil) },
            fileExists: { _ in false }))

        #expect(report.byStatus[.missing] == 1)
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .missing)
    }

    @Test("pages が入っている本は候補にならない")
    func booksWithPagesAreNotScanned() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "d", path: "/lib/d.zip", pages: 30))

        let report = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in
                Issue.record("走査対象外の本を開いた")
                return .failed(reason: "unreachable")
            }))

        #expect(report.scanned == 0)
    }

    @Test("1 冊が失敗しても残りの走査が続く")
    func failureDoesNotStopScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "bad", path: "/lib/bad.zip"))
        try db.insertBook(book(id: 2, title: "good", path: "/lib/good.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { url in
                url.path.contains("bad") ? .failed(reason: "boom")
                                         : .enumerated(count: 5, truncated: false)
            }))

        #expect(report.scanned == 2, "1 冊の失敗で走査が止まっている")
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .damaged)
        #expect(try #require(db.integrityRecord(bookID: 2)).status == .ok)
    }

    /// レビュー指摘: 永続化（upsertIntegrity 等）が throw すると走査全体が止まってしまう
    /// 危険が未検証だった。`book_integrity.book_id` は `REFERENCES book(id) ON DELETE CASCADE`
    /// かつ全接続で `PRAGMA foreign_keys = ON` なので、走査中に本が削除されると
    /// upsertIntegrity の INSERT が FK 違反で本当に throw する（31 時間走る G27b では
    /// 現実的に起こりうるシナリオでもある）。
    @Test("永続化が throw しても残りの走査は続き、失敗件数が報告される")
    func persistenceFailureDoesNotStopScan() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "gone-mid-scan", path: "/lib/e.zip"))
        try db.insertBook(book(id: 2, title: "f", path: "/lib/f.zip"))

        let report = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { url in
                if url.path.contains("e.zip") {
                    // 走査中に本が削除された状況を再現する。
                    try? db.deleteBook(id: 1)
                }
                return .enumerated(count: 5, truncated: false)
            }))

        #expect(report.scanned == 2, "永続化の失敗で走査が止まっている")
        #expect(report.persistenceFailures == 1, "FK 違反による永続化失敗が検知されていない")
        #expect(try db.integrityRecord(bookID: 1) == nil,
                "削除された本の永続化が成功したことになっている")
        #expect(try #require(try db.integrityRecord(bookID: 2)).status == .ok,
                "1 冊目の失敗後、2 冊目が最後まで走査されていない")
    }

    /// `var` を async クロージャの中で書き換えると Swift 6 の並行性チェックに
    /// 引っかかりうるため、`@unchecked Sendable` の収集用クラスに寄せる
    /// (brief 記載の回避策。scan の signature/挙動は変えない)。
    private final class Collector: @unchecked Sendable {
        var seen: [Int] = []
        var totals: [Int] = []
    }

    @Test("進捗が 1 冊ごとに報告される")
    func progressIsReportedPerBook() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))

        let collector = Collector()
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 1, truncated: false) })
        ) { done, total in
            collector.seen.append(done)
            collector.totals.append(total)
        }
        #expect(collector.seen == [1, 2])
        #expect(collector.totals == [2, 2])
    }

    @Test("2 回走らせると 1 回目の結果が prev に退避される")
    func rescanCarriesPreviousGeneration() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))

        // 1 回目: 画像 0 枚(empty) → pages=0 が確定するので 2 回目も候補に残る。
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .enumerated(count: 0, truncated: false) }))
        #expect(try #require(db.integrityRecord(bookID: 1)).status == .empty)

        // 2 回目: 破損に変化。
        _ = try await QuickIntegrityScanner.scan(
            database: db, deps: deps(probe: { _ in .failed(reason: "boom") }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        #expect(rec.status == .damaged)
        #expect(rec.prevStatus == .empty)
    }

    // MARK: - Smoke fix: probeFailureReason は badEntries に path を書かない

    private static let leakyURL = URL(fileURLWithPath: "/Volumes/ecomic/(成年コミック) [雑誌] 2015年11月号.zip")

    @Test("archiveUnreadable は reason だけを残し、URL を含めない")
    func archiveUnreadableReasonExcludesURL() {
        let error = ArchiveAdapterError.archiveUnreadable(Self.leakyURL, reason: "Unrecognized archive format")
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(reason.contains("Unrecognized archive format"))
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains(Self.leakyURL.path))
    }

    @Test("noImageEntry は固定メッセージになり、URL を含めない")
    func noImageEntryReasonExcludesURL() {
        let error = ArchiveAdapterError.noImageEntry(Self.leakyURL)
        let reason = QuickIntegrityScanner.probeFailureReason(for: error)

        #expect(!reason.isEmpty)
        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(!reason.contains(Self.leakyURL.path))
    }

    /// 任意の Error（`ArchiveAdapterError` 以外）は `String(describing:)` を経由させない ――
    /// path を埋め込んだカスタム description を持つ Error が来ても、型名だけの bounded な
    /// 文字列に留まることを確認する。
    @Test("未知のエラー型は String(describing:) にフォールバックせず型名のみ返す")
    func unknownErrorTypeDoesNotLeakDescription() {
        struct LeakyError: Error, CustomStringConvertible {
            var description: String { "failed reading file:///Volumes/ecomic/secret.zip" }
        }

        let reason = QuickIntegrityScanner.probeFailureReason(for: LeakyError())

        #expect(!reason.contains("/Volumes"))
        #expect(!reason.contains("file://"))
        #expect(reason.contains("LeakyError"))
    }

    @Test("probe(.failed) 経由の scan でも badEntries に URL が残らないことを end-to-end で確認する")
    func scanBadEntriesNeverContainsURL() async throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "leaky", path: "/lib/leaky.zip"))

        let error = ArchiveAdapterError.archiveUnreadable(Self.leakyURL, reason: "Unrecognized archive format")
        _ = try await QuickIntegrityScanner.scan(
            database: db,
            deps: deps(probe: { _ in .failed(reason: QuickIntegrityScanner.probeFailureReason(for: error)) }))

        let rec = try #require(try db.integrityRecord(bookID: 1))
        for entry in rec.badEntries {
            #expect(!entry.contains("/Volumes"))
            #expect(!entry.contains("file://"))
        }
    }
}
