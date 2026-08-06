// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
@testable import StackNest

/// `IntegrityWindowLogic` の純関数テスト（Phase G27b Task 6）。
///
/// **ここでテストできるのはウィンドウの表示ロジックだけ**（brief の制約）。
/// 実 `NSWindow` を作る `IntegrityCheckView`/`IntegrityWindowContainer` 自体は App テストで
/// インスタンス化しない — 実 NSWindow を作る App テストはテストホストをクラッシュさせる
/// （測定済み: 13 passing → 0 with "Restarting after unexpected exit"）。
/// 劣化判定そのもの（`IntegrityRecord.isDegraded`）は既に
/// `Tests/LibraryStoreTests/IntegrityStoreTests.swift` でテスト済みのため、ここでは重複させず
/// 「ウィンドウ固有」のロジック（要約文言・表示順・完了メッセージ・ボタン→モードの対応）だけを扱う。
@Suite("IntegrityWindowLogic (G27b Task 6)")
struct IntegrityWindowLogicTests {
    private func book(id: Int, title: String) -> BookRow {
        // デフォルト引数は他の引数（id）を参照できないため、path は常に本体側で id から組み立てる。
        BookRow(id: id, title: title, author: nil, genre: nil, path: "/tmp/\(id).zip",
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    private func record(bookID: Int, status: IntegrityStatus, checkedAt: Int64,
                        prevStatus: IntegrityStatus? = nil) -> IntegrityRecord {
        IntegrityRecord(bookID: bookID, status: status, method: .full, checkedAt: checkedAt,
                        fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
                        prevStatus: prevStatus, prevCheckedAt: nil)
    }

    // MARK: - ScanAction → FullScanMode

    @Test("3 つのボタンはそれぞれ異なる FullScanMode に対応する")
    func scanActionMapsToDistinctModes() {
        #expect(IntegrityWindowLogic.ScanAction.uncheckedOnly.mode == .uncheckedOnly)
        #expect(IntegrityWindowLogic.ScanAction.all.mode == .all)
        #expect(IntegrityWindowLogic.ScanAction.damagedOnly.mode == .damagedOnly)
    }

    @Test("確認が要るのは「全件やり直し」だけ")
    func onlyAllRequiresConfirmation() {
        #expect(IntegrityWindowLogic.ScanAction.uncheckedOnly.needsConfirmation == false)
        #expect(IntegrityWindowLogic.ScanAction.all.needsConfirmation == true)
        #expect(IntegrityWindowLogic.ScanAction.damagedOnly.needsConfirmation == false)
    }

    // MARK: - summaryLine

    @Test("未検査（一度もスキャンしていない）の要約文言")
    func summaryLineWhenNeverScanned() {
        let summary = IntegritySummary(checked: 0, unchecked: 10, damaged: 0, degraded: 0)
        let line = IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: nil)
        #expect(line.contains("最終検査: 未検査"))
        #expect(line.contains("未検査 10 冊"))
        #expect(line.contains("破損 0 冊"))
        #expect(line.contains("劣化 0 冊"))
    }

    @Test("検査済みなら最終検査日時が入り、各件数がそのまま反映される")
    func summaryLineWhenScanned() {
        let summary = IntegritySummary(checked: 90, unchecked: 10, damaged: 3, degraded: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: date)
        #expect(!line.contains("最終検査: 未検査"))
        #expect(line.contains(IntegrityWindowLogic.formattedDate(date)))
        #expect(line.contains("未検査 10 冊"))
        #expect(line.contains("破損 3 冊"))
        #expect(line.contains("劣化 1 冊"))
    }

    // MARK: - completionSummary

    @Test("完走した場合は検査数と破損数を出す")
    func completionSummaryOnFullRun() {
        let report = FullScanReport(scanned: 120, byStatus: [.ok: 115, .damaged: 5],
                                    persistenceFailures: 0, cancelled: false)
        let text = IntegrityWindowLogic.completionSummary(report)
        #expect(text.contains("完了"))
        #expect(text.contains("120"))
        #expect(text.contains("5"))
        #expect(!text.contains("中断"))
    }

    @Test("中断した場合は完了ではなく中断の文言になる")
    func completionSummaryOnCancellation() {
        let report = FullScanReport(scanned: 40, byStatus: [.ok: 40],
                                    persistenceFailures: 0, cancelled: true)
        let text = IntegrityWindowLogic.completionSummary(report)
        #expect(text.contains("中断"))
        #expect(text.contains("40"))
        #expect(!text.contains("完了"))
    }

    @Test("保存失敗があれば件数を明示する")
    func completionSummaryMentionsPersistenceFailures() {
        let report = FullScanReport(scanned: 10, byStatus: [.ok: 9],
                                    persistenceFailures: 2, cancelled: false)
        #expect(IntegrityWindowLogic.completionSummary(report).contains("保存失敗 2 件"))
    }

    // MARK: - sortedForDisplay（劣化を先頭に）

    @Test("劣化行が非劣化行より先頭に来る")
    func degradedRowsSortFirst() {
        let rows: [(book: BookRow, record: IntegrityRecord)] = [
            (book(id: 1, title: "Zoo"), record(bookID: 1, status: .damaged, checkedAt: 100)),
            (book(id: 2, title: "Apple"), record(bookID: 2, status: .damaged, checkedAt: 200, prevStatus: .ok)),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.first?.book.id == 2, "劣化（prevStatus=ok→damaged）が先頭に来るべき")
        #expect(sorted.first?.record.isDegraded == true)
    }

    @Test("劣化どうしは検査が新しい順")
    func degradedRowsSortByMostRecentFirst() {
        let rows: [(book: BookRow, record: IntegrityRecord)] = [
            (book(id: 1, title: "Old"), record(bookID: 1, status: .damaged, checkedAt: 100, prevStatus: .ok)),
            (book(id: 2, title: "New"), record(bookID: 2, status: .damaged, checkedAt: 300, prevStatus: .ok)),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.map(\.book.id) == [2, 1])
    }

    @Test("非劣化どうしはタイトルの辞書順")
    func nonDegradedRowsSortByTitle() {
        let rows: [(book: BookRow, record: IntegrityRecord)] = [
            (book(id: 1, title: "Zebra"), record(bookID: 1, status: .damaged, checkedAt: 100)),
            (book(id: 2, title: "Apple"), record(bookID: 2, status: .damaged, checkedAt: 200)),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.map(\.book.id) == [2, 1])
    }
}
