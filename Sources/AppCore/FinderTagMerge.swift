// SPDX-License-Identifier: MIT
import Foundation

/// 3 方向マージの結果。
public struct FinderTagMergeResult: Equatable, Sendable {
    public let merged: Set<String>
    /// Finder 側へ書き戻す必要があるか（`merged != finder`）。
    public let changedInFinder: Bool
    /// StackNest 側を更新する必要があるか（`merged != library`）。
    public let changedInLibrary: Bool
}

/// 前回同期値を基準に、Finder と StackNest の差分から結果を決める。
///
/// **単純な合併では削除が伝わらない。**一度付いたタグはどちらで消しても復活してしまう。
/// 前回値と比べて初めて「消された」と分かる。
public enum FinderTagMerge {
    public static func merge(baseline: Set<String>?,
                             finder: Set<String>,
                             library: Set<String>) -> FinderTagMergeResult {
        let merged: Set<String>
        if let baseline {
            // 前回から消えた側を落とし、増えた側を足す。
            let removed = baseline.subtracting(finder).union(baseline.subtracting(library))
            let added = finder.subtracting(baseline).union(library.subtracting(baseline))
            // spec §4.1: 真の競合（同じタグを片方が追加・片方が削除）は**追加を優先**。
            // added を後に足すことでそうなる。
            merged = finder.union(library).subtracting(removed).union(added)
        } else {
            // 初回は削除の情報が無いので合併。
            merged = finder.union(library)
        }
        return FinderTagMergeResult(merged: merged,
                                    changedInFinder: merged != finder,
                                    changedInLibrary: merged != library)
    }
}
