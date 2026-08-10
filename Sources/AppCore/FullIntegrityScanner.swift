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
    ///
    /// G27b 最終レビュー Fix3: ライブラリが走査中に閉じられた場合（`DatabaseError.libraryClosed`）も
    /// ここに含める。以後の全冊が同じ理由で失敗し続けるだけの空回りを続けず、打ち切って
    /// `cancelled: true` として終える（詳細は `scan` 内のコメント参照）。
    public let cancelled: Bool
    /// G27b 最終レビュー Fix5: ライブラリの実体（バンドル/ボリューム）自体が到達不能なため
    /// `missing` を書かずにスキップした冊数。NAS/外付けドライブの一時スリープ等、個々の本が
    /// 消えたわけではない可能性が高いケース（詳細は `scan` 内のコメント参照）。
    public let volumeUnavailableSkips: Int

    public init(scanned: Int, byStatus: [IntegrityStatus: Int],
                persistenceFailures: Int = 0, cancelled: Bool = false,
                volumeUnavailableSkips: Int = 0) {
        self.scanned = scanned
        self.byStatus = byStatus
        self.persistenceFailures = persistenceFailures
        self.cancelled = cancelled
        self.volumeUnavailableSkips = volumeUnavailableSkips
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
        /// G27b 最終レビュー Fix5: ライブラリ自体（バンドル/ボリューム）が現在も到達可能かどうか。
        /// `fileExists` が個々の本の 1 ファイルを見るのに対し、こちらはライブラリ全体の生死を見る。
        /// 既定は常に true（既存の全テスト・呼び出しはこの分岐に入らない）。
        public let libraryReachable: @Sendable () -> Bool

        public init(categoryOf: @escaping @Sendable (String) -> BookCategory,
                    fileExists: @escaping @Sendable (String) -> Bool,
                    statFile: @escaping @Sendable (String) -> (Int64?, Double?),
                    verify: @escaping @Sendable (URL, @escaping @Sendable () async -> Bool) async throws -> ArchiveVerifyResult,
                    now: @escaping @Sendable () -> Int64,
                    libraryReachable: @escaping @Sendable () -> Bool = { true }) {
            self.categoryOf = categoryOf
            self.fileExists = fileExists
            self.statFile = statFile
            self.verify = verify
            self.now = now
            self.libraryReachable = libraryReachable
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
        var volumeUnavailableSkips = 0

        for (index, book) in candidates.enumerated() {
            if await isCancelled() {
                cancelled = true
                break
            }

            let path = book.path ?? ""
            let category = deps.categoryOf(path)
            let exists = !path.isEmpty && deps.fileExists(path)

            // G27b 最終レビュー Fix5: `!exists` は「この 1 冊が消えた」だけでなく「ボリューム
            // 自体が一時的に落ちている（NAS/外付けドライブのスリープ・SMB 再接続中 等）」でも
            // 起こる。後者を前者として `missing` を書いてしまうと、確定した既存の判定
            // （ok/damaged いずれも）を「実は消えていた」で上書きし、`.uncheckedOnly` の
            // 次回対象からも外れてしまう ―― 数分のドロップアウトが数千冊分の既存判定を
            // 恒久的に破壊しうる（既に一度直した「劣化を上書きする」不具合と同じクラス）。
            // ライブラリ自体（バンドル/ボリューム）も同時に到達不能なら、これは「本が消えた」
            // ではなく「マウント側の問題」と判断し、この 1 冊は何も書かずスキップする
            // （中断はしない ―― マウントが数分で復帰すれば以降の本は通常どおり検査が続く。
            // isCancelled() は毎冊の先頭で確認しているので、恒久的な障害でもユーザーは
            // いつでも中断できる）。
            if !exists && !deps.libraryReachable() {
                volumeUnavailableSkips += 1
                progress?(index + 1, candidates.count)
                continue
            }

            let (size, mtime) = exists ? deps.statFile(path) : (nil, nil)

            let status: IntegrityStatus
            var pageCount: Int?
            var entryCount: Int?
            var badEntries: [String] = []
            // G27b Codex 2nd review Fix1/2: full スキャンが実際には評価できないカテゴリ
            // （folder/video/text — CRC を持たない・列挙する手段がない）は、すべて同じ規律
            // 「既存の判定（quick スキャンが付けた damaged を含む）を絶対に上書きしない」に従う。
            // 下の永続化ブロックでは分岐せず、共通の原子的パス（insertIntegrityIfAbsent）へ流す。
            // 逆に archive（CRC で評価）・image（サイズで評価）は本当に評価しているので、
            // 従来どおり無条件の upsertIntegrity で書く。
            let isUnassessableCategory: Bool

            if !exists {
                status = .missing
                isUnassessableCategory = false
            } else if category == .video || category == .text {
                // CRC を持つのはアーカイブだけ（spec §4.2）。動画・PDF/テキストは
                // classify() と同じく無条件で unsupported（method='full' で書く ―― でないと
                // .uncheckedOnly に毎回残り続ける）。ただし「無条件で書く」は書き込みの値の話で、
                // 書き込みの可否は folder と同じく既存行の有無に従う（下記 isUnassessableCategory）。
                status = .unsupported
                isUnassessableCategory = true
            } else if category == .image {
                // Task 2 レビュー（Important）: 単独画像を無条件で unsupported にすると、
                // G27a の quick スキャンが 0 バイト画像に付けた damaged（QuickIntegrityCheck.swift
                // の意図的な fail-safe）を、CRC を見ずに黙って消してしまう ―― G27a が
                // 「pages を確定させて候補から永久に外す」形で避けた失敗を、今度は status
                // 経由で再現することになる。full スキャンにも CRC 抜きで判定できる範囲の
                // 真実（ファイルサイズ）はあるので、QuickIntegrityCheck.classify をそのまま
                // 再利用する（probe は image 分岐では使われないので nil でよい）。
                let outcome = QuickIntegrityCheck.classify(
                    category: .image, exists: true, probe: nil, fileSize: size)
                status = outcome.status
                pageCount = outcome.pageCount
                if let reason = outcome.reason { badEntries = [reason] }
                isUnassessableCategory = false
            } else if category == .folder {
                // フォルダの実体検証（列挙）は quick スキャンの担当。full スキャンは CRC
                // 専任で、フォルダを検証する手段（probe）を持たない。classify(probe: nil) は
                // アーカイブ/フォルダ分岐で「probe not performed」を damaged として返すため
                // ここでは呼べない（検証もせず壊れた判定にする方が有害）。
                //
                // Codex 事前レビュー Blocker1 → G27b Codex 2nd review Fix1: 内部レビューは
                // 「現行 2 ライブラリにはフォルダ本が 0 冊」を根拠にこの分岐を deferred にしたが、
                // それは今日のデータの事実であってコードの安全性の話ではない。既存の
                // book_integrity 行があるなら（典型的には quick スキャンが列挙失敗/打ち切りで
                // damaged を付けた行）、full スキャンはそれを評価する手段を持たないので
                // **一切書かない**（checked_at のローテーションも含めて完全に不干渉）。
                // 既存行が無いときだけ unsupported を新規に書く ―― そうしないと
                // .uncheckedOnly が永遠にこの本を対象に残し続けてしまう。
                //
                // 有無の確認と書き込みは、下の共通パス（isUnassessableCategory）が単一の
                // INSERT OR IGNORE で原子的に行う（video/text と同じ）。
                status = .unsupported
                isUnassessableCategory = true
            } else {
                isUnassessableCategory = false
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

            // G27b Codex 2nd review Fix1/2: 評価不能カテゴリ（folder/video/text）は、単一の
            // INSERT OR IGNORE（`insertIntegrityIfAbsent`）で「既存行があれば一切触らない／
            // 無ければ unsupported を新規に書く」を原子的に行う。read-then-write の窓が無いため、
            // quick スキャン（同期エンドポイント。1 ライブラリ 1 ジョブのガード対象外）が同じ本に
            // 割り込んで damaged を書いても、どちらが先着しても既存の判定を失わない。
            if isUnassessableCategory {
                do {
                    let inserted = try database.insertIntegrityIfAbsent(IntegrityRecord(
                        bookID: book.id, status: status, method: .full,
                        checkedAt: deps.now(), fileSize: size, fileMtime: mtime,
                        entryCount: nil, badEntries: [],
                        prevStatus: nil, prevCheckedAt: nil))
                    if inserted {
                        // 新規挿入できた（＝既存行が無かった）ときだけ stat を書き戻し、
                        // 集計に含める。既存行があり insert が no-op だった場合は、
                        // 旧 folder 分岐の規律どおり checked_at のローテーションも含めて
                        // 完全に不干渉のまま次の本へ進む（byStatus にも計上しない ―― この回で
                        // 判定を下したわけではないため）。
                        if let size, let mtime {
                            try database.updateBookFileStat(id: book.id, size: size, mtime: mtime)
                        }
                        byStatus[status, default: 0] += 1
                    }
                } catch DatabaseError.libraryClosed {
                    cancelled = true
                    break
                } catch {
                    persistenceFailures += 1
                }
                progress?(index + 1, candidates.count)
                continue
            }

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
            } catch DatabaseError.libraryClosed {
                // G27b 最終レビュー Fix3: ライブラリが走査の途中で閉じられた
                // （`Database.queue == nil`）。以降の残り全冊も同じ理由で書けないだけの
                // 空回りになる（4.5 秒/冊 × 残り数万冊を最大 31 時間かけて何も書かずに読み
                // 続けてしまう）ので、per-book failure として数えて続行するのではなく、
                // ここで打ち切って中断（cancelled: true）として終える。
                cancelled = true
                break
            } catch {
                persistenceFailures += 1
            }

            progress?(index + 1, candidates.count)
        }

        return FullScanReport(scanned: scanned, byStatus: byStatus,
                              persistenceFailures: persistenceFailures, cancelled: cancelled,
                              volumeUnavailableSkips: volumeUnavailableSkips)
    }
}

extension FullIntegrityScanner {
    /// 本番用の I/O 実装。CRC 検証は `ArchiveIntegrityVerifier` に委ねる。
    ///
    /// G27b 最終レビュー Fix5: `libraryBundleURL` はライブラリバンドル自身のパス
    /// （例: `.../MyLibrary.stacknest`）。`!exists` になった本がある度に、この 1 パスの
    /// 存在確認だけで「ボリューム/バンドルごと消えている」か「その本だけが本当に消えた」かを
    /// 判別する（ファイル 1 個の stat なので走査全体のコストには効かない）。
    ///
    /// G34a: CRC 検証は `ThrottledIOExecutor` の専用スレッド（低 QoS ＋ `IOPOL_THROTTLE`）で走らせる。
    /// 従来はこの検証が**呼び出し元（GUI＝`@MainActor`）の優先度を継承した非構造 Task 上**で
    /// 走っており、実測で `PRI=46`（Finder / Safari のメインスレッド相当）だった。
    /// 走査は時間の 70% を `read()` に費やす I/O 律速で、UI が読むもの（本体・サムネイル・SQLite）は
    /// 同じディスクイメージ上にあるため、UI の read が背後に並んで**アプリだけがもっさり**していた。
    ///
    /// 実行器は**この Dependencies に 1 個**（＝1 回の走査に 1 個）。直列なので、ディスクイメージへの
    /// 同時要求を増やさない。
    public static func liveDependencies(libraryBundleURL: URL) -> Dependencies {
        let executor = ThrottledIOExecutor()
        return Dependencies(
            categoryOf: { BookCategory.classify(path: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            statFile: { Database.statFile($0) },
            verify: { url, isCancelled in
                // 検証は同期ループなので、actor 越しの async な中断問い合わせを
                // 同期的に読めるフラグへ写してから渡す（詳細は CancellationMirror）。
                try await CancellationMirror.mirroring(probe: isCancelled) { syncIsCancelled in
                    try await executor.run {
                        try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: syncIsCancelled)
                    }
                }
            },
            now: { Int64(Date().timeIntervalSince1970) },
            libraryReachable: { FileManager.default.fileExists(atPath: libraryBundleURL.path) })
    }
}
