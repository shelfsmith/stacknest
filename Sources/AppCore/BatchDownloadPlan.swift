// SPDX-License-Identifier: MIT
import Foundation

/// 一括ダウンロード対象の算出（純粋ロジック・テスト可能）。
public enum BatchDownloadPlan {
    /// 選択 id のうち未 DL のものを昇順で返す（既 DL はスキップ）。
    public static func pending(selected: Set<Int>, isDownloaded: (Int) -> Bool) -> [Int] {
        selected.filter { !isDownloaded($0) }.sorted()
    }
}
