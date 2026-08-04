// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter
import LibraryStore

/// 簡易スキャンの結果サマリ。
public struct QuickScanReport: Sendable, Equatable {
    public let scanned: Int
    public let byStatus: [IntegrityStatus: Int]
    /// pages を書き戻した冊数（④ の収束量）。
    public let pagesUpdated: Int
    /// 永続化（upsertIntegrity / updateBookPages / updateBookFileStat）が throw した冊数。
    /// SQLite busy/locked・ディスク full・走査中の本削除（FK 違反）等で発生しうる。
    /// この冊は byStatus にも pagesUpdated にも計上されない（実際に書けていないため）が、
    /// 走査自体は次の本へ続行する。0 でなければ呼び出し側は再走査を検討すべき。
    public let persistenceFailures: Int

    public init(scanned: Int, byStatus: [IntegrityStatus: Int], pagesUpdated: Int,
                persistenceFailures: Int = 0) {
        self.scanned = scanned
        self.byStatus = byStatus
        self.pagesUpdated = pagesUpdated
        self.persistenceFailures = persistenceFailures
    }
}

/// `pages` が未取得の本だけを実際に開いて分類し、結果を永続化する（spec §4.2 / §4.6）。
///
/// 実測では 22,880 冊中 65 冊が候補で数分で終わる。全件を CRC 検証する詳細スキャンは G27b。
public enum QuickIntegrityScanner {
    /// I/O をすべて注入可能にして、テストから実ファイル無しで全分岐を通せるようにする。
    public struct Dependencies: Sendable {
        public let categoryOf: @Sendable (String) -> BookCategory
        public let fileExists: @Sendable (String) -> Bool
        public let statFile: @Sendable (String) -> (Int64?, Double?)
        public let probe: @Sendable (URL) async -> QuickProbe
        public let now: @Sendable () -> Int64

        public init(categoryOf: @escaping @Sendable (String) -> BookCategory,
                    fileExists: @escaping @Sendable (String) -> Bool,
                    statFile: @escaping @Sendable (String) -> (Int64?, Double?),
                    probe: @escaping @Sendable (URL) async -> QuickProbe,
                    now: @escaping @Sendable () -> Int64) {
            self.categoryOf = categoryOf
            self.fileExists = fileExists
            self.statFile = statFile
            self.probe = probe
            self.now = now
        }
    }

    /// 候補を順に検査し、1 冊ごとに結果をコミットする。
    /// 失敗した本は damaged として記録し、走査は続行する（1 冊で全体が止まらない）。
    @discardableResult
    public static func scan(database: Database,
                            deps: Dependencies,
                            progress: ((Int, Int) -> Void)? = nil) async throws -> QuickScanReport {
        let candidates = try database.booksNeedingQuickCheck()
        var byStatus: [IntegrityStatus: Int] = [:]
        var pagesUpdated = 0
        var persistenceFailures = 0

        for (index, book) in candidates.enumerated() {
            let path = book.path ?? ""
            let category = deps.categoryOf(path)
            let exists = !path.isEmpty && deps.fileExists(path)

            var probeResult: QuickProbe?
            if exists && QuickIntegrityCheck.needsProbe(category: category) {
                probeResult = await deps.probe(URL(fileURLWithPath: path))
            }

            let outcome = QuickIntegrityCheck.classify(
                category: category, exists: exists, probe: probeResult)

            let (size, mtime) = exists ? deps.statFile(path) : (nil, nil)
            let entryCount: Int? = {
                if case .enumerated(let c, _) = probeResult { return c }
                return outcome.pageCount
            }()

            // 永続化は per-book で失敗しうる（SQLite busy/locked・ディスク full・
            // 走査中に本が削除された場合の FK 違反 等）。1 冊の失敗で走査全体を
            // 止めない ―― do/catch で握り潰さず件数に残し、次の本へ進む。
            do {
                try database.upsertIntegrity(IntegrityRecord(
                    bookID: book.id, status: outcome.status, method: .quick,
                    checkedAt: deps.now(), fileSize: size, fileMtime: mtime,
                    entryCount: entryCount,
                    badEntries: outcome.reason.map { [$0] } ?? [],
                    prevStatus: nil, prevCheckedAt: nil))

                // ④: 確定できたときだけ pages を書き戻す。破損本は書かない（G26 の規則と同じ）。
                if let pageCount = outcome.pageCount {
                    try database.updateBookPages(id: book.id, newPages: pageCount)
                    pagesUpdated += 1
                }
                // file_size / file_mtime も同じ機会に埋める（実機で 99.5% が NULL だったのを解消）。
                if let size, let mtime {
                    try database.updateBookFileStat(id: book.id, size: size, mtime: mtime)
                }

                byStatus[outcome.status, default: 0] += 1
            } catch {
                persistenceFailures += 1
            }

            progress?(index + 1, candidates.count)
        }

        return QuickScanReport(scanned: candidates.count, byStatus: byStatus,
                               pagesUpdated: pagesUpdated, persistenceFailures: persistenceFailures)
    }
}
