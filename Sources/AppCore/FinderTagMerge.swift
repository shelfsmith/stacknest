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
///
/// ## 「同じタグを片方が追加・もう片方が削除」は起こらない
///
/// spec §4.1 は当初これを「真の競合」として扱い、追加を優先すると決めていた。
/// **だがこの状態は到達不能である**（総当たりで確認）——
/// 「削除」は baseline にあることを、「追加」は baseline に無いことを要求するので、
/// 同じタグについて両立しない。
///
/// 実在するのは**非対称な形**だけ: 片方の変更が baseline から見えない場合
/// （例: 前回同期のあと StackNest 側で消して付け直すと、baseline から見て無変化になる）。
/// このとき**baseline に対して見える側の変更が勝つ**。それが下の式の意味であり、
/// 「追加を優先」でも「削除を優先」でもない。
public enum FinderTagMerge {
    public static func merge(baseline: Set<String>?,
                             finder: Set<String>,
                             library: Set<String>) -> FinderTagMergeResult {
        let merged: Set<String>
        if let baseline {
            // 前回から消えた側を落とし、増えた側を足す。
            // 前回から**消えた**タグ（どちらか一方でも消していれば消えたとみなす）。
            let removed = baseline.subtracting(finder).union(baseline.subtracting(library))
            // 増えたタグは `finder ∪ library` に既に含まれ、`removed` とは必ず素なので
            // （増えた＝baseline に無い / 消えた＝baseline にある）、明示的に足す必要はない。
            // **当初は `.union(added)` を書いていたが、数学的に no-op だった**
            //（実装者が 4096 通りの総当たりで証明。コメントは「追加を優先する仕組み」と
            // 説明していたが、実際には何もしていなかった）。
            merged = finder.union(library).subtracting(removed)
        } else {
            // 初回は削除の情報が無いので合併。
            merged = finder.union(library)
        }
        return FinderTagMergeResult(merged: merged,
                                    changedInFinder: merged != finder,
                                    changedInLibrary: merged != library)
    }
}
