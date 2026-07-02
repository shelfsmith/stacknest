// SPDX-License-Identifier: MIT
import Foundation

/// `.lastOpened` 起動での復元計画（C-④a）。
public struct StartupRestorePlan: Equatable, Sendable {
    /// 開くべき URL 列（空ならタイトル画面）。
    public let urls: [URL]
    /// 「前回開く意図があったのに全滅した」＝アラート対象か。
    /// 意図的に何も開いていなかった（open-set が空）場合は false（アラートを出さない）。
    public let failedToRestore: Bool
    public init(urls: [URL], failedToRestore: Bool) {
        self.urls = urls
        self.failedToRestore = failedToRestore
    }
}

/// `.lastOpened` 起動で復元すべきライブラリ URL を解決する純ロジック（C-④a）。
public enum StartupRestore {
    /// 復元計画（開く URL ＋ 失敗アラート要否）を返す。App 層はこの結果で窓オープン/アラートを分岐する。
    /// - openSet: 前回終了時に開いていた庫の集合（nil = 未書込＝アップグレード直後/新規・[] = 意図的に空）。
    /// - recencyFirst: 最近開いた先頭 1 庫（未書込フォールバック＋フォーカス用）。
    /// - exists: bundle が現存し妥当か。
    public static func plan(openSet: [URL]?, recencyFirst: URL?, exists: (URL) -> Bool) -> StartupRestorePlan {
        let urls = librariesToRestore(openSet: openSet, recencyFirst: recencyFirst, exists: exists)
        // 復元「意図」があったか: open-set が非空（＝前回何か開いていた）／未書込なら recency を試みる。
        // open-set が空（[]）＝意図的に全部閉じて終了 → 意図なし＝アラート不要。
        let hadIntent: Bool
        if let openSet {
            hadIntent = !openSet.isEmpty
        } else {
            hadIntent = recencyFirst != nil
        }
        return StartupRestorePlan(urls: urls, failedToRestore: hadIntent && urls.isEmpty)
    }

    /// 開くべき URL 列（存在するもののみ・recencyFirst を末尾へ寄せてフォーカス対象に）。
    /// - openSet: 前回終了時に開いていた庫の集合（nil = 未書込）。
    public static func librariesToRestore(openSet: [URL]?, recencyFirst: URL?, exists: (URL) -> Bool) -> [URL] {
        let base: [URL]
        if let openSet {
            base = openSet.filter(exists)
        } else if let recencyFirst, exists(recencyFirst) {
            base = [recencyFirst]
        } else {
            base = []
        }
        guard let recencyFirst, base.contains(recencyFirst) else { return base }
        return base.filter { $0 != recencyFirst } + [recencyFirst]
    }
}
