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

            // Fix4: classify の .image 分岐がサイズを見て判定できるよう、probe より前に stat する
            // （0 バイト画像を「開かずに確定できる 1 ページ」として ok にしてしまわないため）。
            let (size, mtime) = exists ? deps.statFile(path) : (nil, nil)

            var probeResult: QuickProbe?
            if exists && QuickIntegrityCheck.needsProbe(category: category) {
                probeResult = await deps.probe(URL(fileURLWithPath: path))
            }

            let outcome = QuickIntegrityCheck.classify(
                category: category, exists: exists, probe: probeResult, fileSize: size)

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

extension QuickIntegrityScanner {
    /// 本番用の I/O 実装。列挙は既存の extractor に委ねる。
    ///
    /// **archive と folder で extractor が異なる**ため、URL がディレクトリかどうかで振り分ける
    /// （`CoverRefresher` / `BookContent` が archive/folder を dispatch する方法に合わせた）。
    public static func liveDependencies(
        archiveExtractor: any CoverImageExtractor,
        folderExtractor: any CoverImageExtractor
    ) -> Dependencies {
        Dependencies(
            categoryOf: { BookCategory.classify(path: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            statFile: { Database.statFile($0) },
            probe: { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let extractor = isDir ? folderExtractor : archiveExtractor
                do {
                    let listing = try await extractor.listImageEntries(in: url)
                    return .enumerated(count: listing.names.count, truncated: listing.truncated)
                } catch {
                    return .failed(reason: probeFailureReason(for: error))
                }
            },
            now: { Int64(Date().timeIntervalSince1970) })
    }

    /// probe (`listImageEntries`) が throw したエラーを、badEntries に安全に書ける
    /// reason 文字列へ変換する。
    ///
    /// この reason は `book_integrity.bad_entries` に永続化され、read tier トークンでも
    /// `GET .../integrity/list` からそのまま返る（path を秘匿する filename 化と同じ規約が
    /// ここにも及ぶ）。`ArchiveAdapterError` の全ケースは絶対パスの `URL` を保持しているため、
    /// **URL を含めず** 診断に有用な部分（ケース種別 / 正規化した分類名）だけを取り出す。
    /// 実機 smoke（G27a）で `archiveUnreadable` の `String(describing:)` がそのまま
    /// `file:///Volumes/...` を含んだ reason を書き出していた実例がある。
    ///
    /// **G27a task 8（Codex High #2）**: 上の smoke fix は `.archiveUnreadable` の `reason` 文字列
    /// （libarchive `archive_error_string()` の生文字列）を URL 抜きでそのまま通していたが、
    /// 権限拒否・ファイル不在では **その reason 自体に絶対パスが埋め込まれる**
    /// （実測: `Failed to open '/tmp/g27a-errs/noperm.zip'`）。1 ケース（"Unrecognized archive
    /// format"＝path を含まない）だけを見て「塞いだ」と判断したのが今回の見落としの原因だった。
    /// そこで **libarchive の生文字列は理由を問わず一切永続化しない** ―― `classifyOpenFailure`
    /// で固定の分類名へ正規化し、原文は捨てる。
    static func probeFailureReason(for error: Error) -> String {
        if let archiveError = error as? ArchiveAdapterError {
            switch archiveError {
            case .archiveUnreadable(_, let reason):
                return "archive unreadable: \(classifyOpenFailure(reason))"
            case .enumerationFailed:
                // header-read ループ内での破綻。libarchive の文言は破損パターンごとに
                // 全く異なり（"Damaged Zip archive" 等）安全に分類できないため、
                // reason の中身は一切見ずに固定文言のみを返す。
                return "archive read truncated"
            case .noImageEntry:
                return "no image entry found"
            }
        }
        return "probe failed: \(type(of: error))"
    }

    /// `.archiveUnreadable` の reason（open 自体が失敗した段の libarchive 生文字列、または
    /// 本実装自身が使う英語リテラル）を、パスを含まない固定分類へ正規化する。
    ///
    /// 実測（controller, 2026-08-06・libarchive 直叩き）:
    /// - `Unrecognized archive format`（中身がアーカイブでない／ランダムバイト列／0 バイト）→ path なし
    /// - `Failed to open '<絶対パス>'`（権限拒否／ファイル不在）→ **path あり**
    ///
    /// 未知の文言（将来 libarchive のメッセージが変わった場合を含む）は「それ以外」に落ちるだけで、
    /// 原文を返すことは決してない。
    static func classifyOpenFailure(_ raw: String) -> String {
        if raw.hasPrefix("Failed to open") {
            return "could not open archive"
        }
        if raw.contains("Unrecognized archive format") {
            return "unrecognized archive format"
        }
        // 本実装自身が open 段の throw で使う英語リテラル（FolderCoverExtractor 含む）。
        // libarchive の生文字列ではないので path は含まれないが、分類は揃えておく。
        if raw == "archive_read_new failed" || raw == "open failed" || raw == "not a directory" {
            return "could not open archive"
        }
        return "unexpected archive read failure"
    }
}
