// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// 監視フォルダ走査の「何を取り込むべきか」を決める部分（G35a-1）。
///
/// ## なぜ切り出したか
///
/// この判定は元々 `FolderWatcher.scanAll()` の中にあり、クラスごと `@MainActor` だった。
/// 中身は **DB 読み・ディレクトリ列挙・サイズ集計・安定判定**で、**どれも MainActor を必要としない**
/// にもかかわらずメインスレッド上で走っていた ―― しかも **60 秒タイマー＋vnode イベント**で、
/// **開いている庫ごとに**（一般コミック 10,752 冊 ＋ e_comic 12,180 冊）。
///
/// 実測（2026-08-11・ただし高負荷マシン上のため絶対値は要再測）では、スクロール中の
/// メインスレッド実働の **37%** がここだった（内訳: ディレクトリ列挙 2,292 / `fetchAllBooks` 1,662）。
/// ライブラリは USB HDD 上の暗号化ディスクイメージにあり、1 操作 36〜80ms かかる。
///
/// ## 移設であって仕様変更ではない
///
/// 判定そのものは既存の `WatchFolderScanner`（`importable` / `decideStable` / `filterRetry`）を
/// そのまま使う。**挙動を変えないこと**が本切り出しの前提。
/// 副次的な利得として、`FolderWatcher` には**テストが 1 本も無かった**のがテスト可能になる。
public enum WatchScanPlanner {

    /// 候補 1 件と、それがどの監視フォルダ由来かの対応。
    /// **フォルダを持ち回るのは取り込み時のプリセット（ファイル名フォーマット）解決に要るため。**
    /// 落とすと別フォルダの書式で取り込まれる。
    public struct Candidate: Sendable, Equatable {
        public let url: URL
        public let folder: WatchedFolder

        public init(url: URL, folder: WatchedFolder) {
            self.url = url
            self.folder = folder
        }
    }

    /// 走査 1 回分の計画。
    public struct Plan: Sendable {
        /// 今回取り込みを試みるパス（サイズが安定し、拒否記憶にも当たらなかったもの）。
        public let attemptable: [String]
        /// `attemptable` を含む全候補の由来。
        public let candidatesByPath: [String: Candidate]
        /// 今回観測したサイズ（サイズ 0 は載らない。下記 `plan` 参照）。
        public let currentSizes: [String: Int64]
        /// 次回の `lastSizes` にする値（まだ安定していない候補）。
        public let pending: [String: Int64]

        /// まだ安定していない候補があるか。呼び出し側は真なら短時間で再走査する。
        public var hasPending: Bool { !pending.isEmpty }

        public init(attemptable: [String], candidatesByPath: [String: Candidate],
                    currentSizes: [String: Int64], pending: [String: Int64]) {
            self.attemptable = attemptable
            self.candidatesByPath = candidatesByPath
            self.currentSizes = currentSizes
            self.pending = pending
        }
    }

    /// I/O をすべて注入可能にして、テストから実ファイル無しで全分岐を通せるようにする
    /// （`FullIntegrityScanner.Dependencies` と同じ流儀）。
    public struct IO: Sendable {
        public let existingPaths: @Sendable () -> Set<String>
        public let enumerate: @Sendable (URL, WatchedFolder.SubfolderMode) -> [URL]
        public let totalSize: @Sendable (URL) -> Int64

        public init(existingPaths: @escaping @Sendable () -> Set<String>,
                    enumerate: @escaping @Sendable (URL, WatchedFolder.SubfolderMode) -> [URL],
                    totalSize: @escaping @Sendable (URL) -> Int64) {
            self.existingPaths = existingPaths
            self.enumerate = enumerate
            self.totalSize = totalSize
        }

        /// 本番用。`database` は `@unchecked Sendable` なので、そのまま渡してオフスレッドで読める。
        public static func live(database: Database) -> IO {
            IO(existingPaths: { (try? database.allBookPaths()) ?? [] },
               enumerate: { WatchFolderScanner.enumerateCandidates(folder: $0, mode: $1) },
               totalSize: { WatchScanPlanner.totalSize(of: $0) })
        }
    }

    /// 今回の走査で「何を取り込むか」を決める。**I/O はするが状態は持たない。**
    ///
    /// - Parameters:
    ///   - folders: **呼び出し側で `enabled` を絞り、スナップショット済みのもの**を渡す。
    ///     走査中に設定が変わっても、1 回の走査は最初に見た設定で最後まで通す
    ///     （途中で読み直すと一部だけ新しい設定という中途半端な状態になる）。
    ///   - lastSizes: 前回の観測サイズ。2 回連続で同一なら「安定」＝取り込み可と判断する。
    ///   - rejectedSizes: フォルダゲートに弾かれた候補の「拒否時サイズ」。
    ///     同サイズのままなら再試行しない（さもないと「1 件失敗」バナーが 60 秒ごとに永久に出る）。
    public static func plan(folders: [WatchedFolder],
                            lastSizes: [String: Int64],
                            rejectedSizes: [String: Int64],
                            io: IO) -> Plan {
        let existing = io.existingPaths()
        var currentSizes: [String: Int64] = [:]
        var candidatesByPath: [String: Candidate] = [:]

        for folder in folders {
            let dir = URL(fileURLWithPath: folder.path)
            let top = io.enumerate(dir, folder.subfolderMode)
            let importable = WatchFolderScanner.importable(
                topLevel: top,
                existingLibraryPaths: existing,
                baseline: Set(folder.baseline))
            for url in importable {
                let size = io.totalSize(url)
                // サイズ 0 の候補は記録しない（移設元のコメントをそのまま維持）。
                // 空フォルダ（archive モードの新規サブフォルダ）や 0byte ファイルは、2 回連続で
                // 観測しても常に 0==0 で「安定」と誤判定され、コピー完了前・中身がまだ空の状態で
                // 取り込まれてしまう。一度取り込むと path がライブラリ既存になり、コピー完了後も
                // 二度と再取込されない事故になるため、そもそも current に載せず lastSizes にも
                // 残さない＝次スキャンでサイズが付いてから改めて安定判定させる。
                guard size > 0 else { continue }
                currentSizes[url.path] = size
                candidatesByPath[url.path] = Candidate(url: url, folder: folder)
            }
        }

        let decision = WatchFolderScanner.decideStable(previous: lastSizes, current: currentSizes)
        let attemptable = WatchFolderScanner.filterRetry(
            stable: decision.stable, currentSizes: currentSizes, rejectedSizes: rejectedSizes)

        return Plan(attemptable: attemptable,
                    candidatesByPath: candidatesByPath,
                    currentSizes: currentSizes,
                    pending: decision.pending)
    }

    /// ファイル 1 個ならそのサイズ、ディレクトリなら配下の合計サイズ。
    /// （`FolderWatcher.totalSize` から移設。挙動は不変。）
    public static func totalSize(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var sum: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                sum += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return sum
    }
}
