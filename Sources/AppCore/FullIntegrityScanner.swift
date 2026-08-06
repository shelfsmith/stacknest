// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter
import LibraryStore

/// 詳細スキャンの結果サマリ。
public struct FullScanReport: Sendable, Equatable {
    public let scanned: Int
    public let byStatus: [IntegrityStatus: Int]
    /// 永続化（upsertIntegrity / updateBookPages / updateBookFileStat）が throw した冊数。
    /// `QuickScanReport.persistenceFailures` と同じ意味（SQLite busy/locked・走査中の
    /// 本削除による FK 違反等）。この冊は scanned にも byStatus にも計上されない。
    public let persistenceFailures: Int
    /// `isCancelled` により走査が完走せず打ち切られたか。
    public let cancelled: Bool

    public init(scanned: Int, byStatus: [IntegrityStatus: Int],
                persistenceFailures: Int = 0, cancelled: Bool = false) {
        self.scanned = scanned
        self.byStatus = byStatus
        self.persistenceFailures = persistenceFailures
        self.cancelled = cancelled
    }
}

/// アーカイブ全件の CRC 検証を行い、結果を永続化する（spec §4.2/§4.3、Phase G27b）。
///
/// **`QuickIntegrityScanner` と同じ規律を踏襲する**: 1 冊ごとにコミット・1 冊の失敗で
/// 全体を止めない・破損時に `pages` を書かない。唯一の大きな違いは、31 時間規模の走査を
/// 想定して **`isCancelled` を冊単位・エントリ単位の両方で見る**こと（`ArchiveIntegrityVerifier`
/// がエントリ単位を担当し、このスキャナは冊単位の境界を担当する）。
public enum FullIntegrityScanner {
    /// I/O をすべて注入可能にして、テストから実ファイル無しで全分岐を通せるようにする。
    public struct Dependencies: Sendable {
        public let categoryOf: @Sendable (String) -> BookCategory
        public let fileExists: @Sendable (String) -> Bool
        public let statFile: @Sendable (String) -> (Int64?, Double?)
        public let verify: @Sendable (URL, @escaping @Sendable () async -> Bool) async throws -> ArchiveVerifyResult
        public let now: @Sendable () -> Int64

        public init(categoryOf: @escaping @Sendable (String) -> BookCategory,
                    fileExists: @escaping @Sendable (String) -> Bool,
                    statFile: @escaping @Sendable (String) -> (Int64?, Double?),
                    verify: @escaping @Sendable (URL, @escaping @Sendable () async -> Bool) async throws -> ArchiveVerifyResult,
                    now: @escaping @Sendable () -> Int64) {
            self.categoryOf = categoryOf
            self.fileExists = fileExists
            self.statFile = statFile
            self.verify = verify
            self.now = now
        }
    }

    /// 候補を順に検査し、1 冊ごとに結果をコミットする。
    ///
    /// 冊単位の中断は各冊の**開始前**に確認する。加えて、`verify` がエントリ単位の中断で
    /// `truncated: true` を返してきた場合は、それが**破損由来か中断由来かをここで見分ける**
    /// （`isCancelled()` を再確認する）。中断由来なら、その本は**一切永続化しない**まま
    /// 走査を終える ―― 中途半端な `damaged` を書き込むと、その本が `method='full'` の
    /// 行を持つことになり `.uncheckedOnly` の次回候補から外れてしまい、「中断からの再開」が
    /// 成立しなくなるため（brief の候補クエリと矛盾しない設計にするための要）。
    /// 破損由来（中断されていない）なら、通常どおり `damaged` として記録する。
    @discardableResult
    public static func scan(database: Database,
                            mode: FullScanMode = .uncheckedOnly,
                            deps: Dependencies,
                            progress: ((Int, Int) -> Void)? = nil,
                            isCancelled: @escaping @Sendable () async -> Bool = { false }) async throws -> FullScanReport {
        let candidates = try database.booksNeedingFullCheck(mode: mode)
        var byStatus: [IntegrityStatus: Int] = [:]
        var persistenceFailures = 0
        var scanned = 0
        var cancelled = false

        for (index, book) in candidates.enumerated() {
            if await isCancelled() {
                cancelled = true
                break
            }

            let path = book.path ?? ""
            let category = deps.categoryOf(path)
            let exists = !path.isEmpty && deps.fileExists(path)
            let (size, mtime) = exists ? deps.statFile(path) : (nil, nil)

            let status: IntegrityStatus
            var pageCount: Int?
            var entryCount: Int?
            var badEntries: [String] = []

            if !exists {
                status = .missing
            } else if category != .archive {
                // CRC を持つのはアーカイブだけ（spec §4.2）。動画・PDF・単独画像・フォルダは
                // ここで unsupported を書く ―― 書かないと .uncheckedOnly に毎回残り続ける。
                status = .unsupported
            } else {
                do {
                    let result = try await deps.verify(URL(fileURLWithPath: path), isCancelled)
                    entryCount = result.entryCount
                    if result.truncated {
                        if await isCancelled() {
                            // 中断由来。この本は未検証のまま扱う ―― 永続化せず走査を終える。
                            cancelled = true
                            break
                        }
                        status = .damaged
                        badEntries = result.badEntries.isEmpty
                            ? ["archive read truncated"] : result.badEntries
                    } else if !result.badEntries.isEmpty {
                        status = .damaged
                        badEntries = result.badEntries
                    } else if result.imageCount == 0 {
                        // 画像 0 枚は「確定した 0」。毎回再走査しないよう pages=0 を書いてよい
                        // （QuickIntegrityCheck.classify と同じ扱い）。
                        status = .empty
                        pageCount = 0
                    } else {
                        status = .ok
                        pageCount = result.imageCount
                    }
                } catch {
                    // open 自体の失敗（非アーカイブ・権限拒否・ファイル不在等）。libarchive の
                    // 生エラー文字列は絶対パスを含みうるため、QuickIntegrityScanner と同じ
                    // 正規化を通す（同一モジュール内 = internal メソッドをそのまま再利用できる）。
                    status = .damaged
                    badEntries = [QuickIntegrityScanner.probeFailureReason(for: error)]
                }
            }

            // ここまで到達した本は「試みた」冊数として数える ―― 永続化に成功したか否かに
            // 関わらず（QuickScanReport.scanned と同じ意味 = candidates のうち実際に処理を
            // 試みた数。中断で break した本はここに到達しないため含まれない）。
            scanned += 1

            // 永続化は per-book で失敗しうる（SQLite busy/locked・ディスク full・
            // 走査中に本が削除された場合の FK 違反 等）。1 冊の失敗で走査全体を
            // 止めない ―― do/catch で握り潰さず件数に残し、次の本へ進む。
            do {
                try database.upsertIntegrity(IntegrityRecord(
                    bookID: book.id, status: status, method: .full,
                    checkedAt: deps.now(), fileSize: size, fileMtime: mtime,
                    entryCount: entryCount, badEntries: badEntries,
                    prevStatus: nil, prevCheckedAt: nil))

                // 確定できたときだけ pages を書き戻す。破損本は書かない（G26/G27a の規則と同じ）。
                if let pageCount {
                    try database.updateBookPages(id: book.id, newPages: pageCount)
                }
                if let size, let mtime {
                    try database.updateBookFileStat(id: book.id, size: size, mtime: mtime)
                }

                byStatus[status, default: 0] += 1
            } catch {
                persistenceFailures += 1
            }

            progress?(index + 1, candidates.count)
        }

        return FullScanReport(scanned: scanned, byStatus: byStatus,
                              persistenceFailures: persistenceFailures, cancelled: cancelled)
    }
}

extension FullIntegrityScanner {
    /// 本番用の I/O 実装。CRC 検証は `ArchiveIntegrityVerifier` に委ねる。
    public static func liveDependencies() -> Dependencies {
        Dependencies(
            categoryOf: { BookCategory.classify(path: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            statFile: { Database.statFile($0) },
            verify: { url, isCancelled in
                try await ArchiveIntegrityVerifier.verify(url: url, isCancelled: isCancelled)
            },
            now: { Int64(Date().timeIntervalSince1970) })
    }
}
