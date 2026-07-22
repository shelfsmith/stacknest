// SPDX-License-Identifier: MIT
import Foundation
import OSLog

/// G21 #6-2: サーバ実行時 temp（`stacknest-arc-<uuid>`＝SequentialArchiveExtractor の展開先）は
/// 通常 deinit で消えるが、プロセスが強制終了すると残る。起動時に古いものだけ掃除する。
///
/// **24 時間 TTL にする理由**: 同時に別インスタンスが稼働している可能性がある。稼働中の
/// インスタンスの temp は継続的にアクセス・作成されるため 24 時間より古くなることは実質なく、
/// 逆に使用中の temp を消すと閲覧中の本が壊れる。PID 方式は temp 名の規約変更が必要で、
/// かつ旧形式の残骸は結局 TTL で消すことになるため採らない。
///
/// **mtime 検証（実装時に確認済み）**: この安全論法は「ディレクトリの mtime が新規ページ抽出の
/// たびに更新される」ことに依存する。APFS で実測したところ、ディレクトリへの**エントリ追加**
/// （＝新規ファイル作成）はディレクトリ自身の mtime を更新するが、**既存ファイルへの書き込み**は
/// 更新しない（ファイル自身の mtime のみ変わる）。SequentialArchiveExtractor は各エントリを
/// 一度だけ抽出してキャッシュし、以後は既存ファイルを読むだけで書き直さないため、ディレクトリの
/// mtime は「そのディレクトリ配下で最後に新規作成されたファイルの時刻」と等しい＝
/// 「配下ファイルの最新 mtime」と同値になる。したがってディレクトリ自身の mtime を見るだけで
/// 十分であり、配下ファイルを個別に走査する必要はない。
///
/// **残る限界**: 本を最後まで読み切って（全ページ抽出済み＝新規ファイル作成が止まった）以降、
/// 同じプロセスを 24 時間より長く開きっぱなしで放置した場合、そのディレクトリの mtime は
/// 更新され続けない。その状態で別インスタンスが起動して掃除すると、稼働中だが「非活動」な
/// temp を消してしまう可能性はゼロではない。PID 方式を採らない以上この残余リスクは残るが、
/// 「本を読んでいる最中に消える」典型的な事故（アクティブなページ送り中）は防げる。
enum TempSweeper {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "TempSweeper")

    /// `directory` 直下の `prefix` で始まるディレクトリのうち、mtime が `olderThan` 秒より古いものを削除する。
    /// 削除できた件数を返す。best-effort（失敗しても投げない）。
    @discardableResult
    static func sweep(in directory: URL, prefix: String, olderThan: TimeInterval, now: Date) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for url in entries {
            guard url.lastPathComponent.hasPrefix(prefix) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true, let mtime = values?.contentModificationDate else { continue }
            guard now.timeIntervalSince(mtime) > olderThan else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            logger.info("swept \(removed, privacy: .public) stale temp dir(s) older than \(Int(olderThan), privacy: .public)s")
        }
        return removed
    }

    /// 既定の掃除（プロセス起動後、実際に呼ばれた最初の 1 回だけ実行）。`stacknest-arc-*` を
    /// 24 時間 TTL で掃く。`static let` の遅延初期化は Swift ランタイムが排他的に一度だけ走らせる
    /// ことを保証するため、呼び出し側（本番のサーバ起動経路が複数回呼んでもよい）が何度呼んでも
    /// 実処理は 1 回に収まる。
    static func sweepRuntimeTemp() {
        _ = sweepOnce
    }

    private static let sweepOnce: Void = {
        sweep(in: FileManager.default.temporaryDirectory,
              prefix: "stacknest-arc-", olderThan: 24 * 3600, now: Date())
    }()
}
