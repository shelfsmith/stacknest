// SPDX-License-Identifier: MIT
import Foundation

/// B18 (Phase 2.5g): 新規追加 book の bookType (Stackroom int) を URL + 画像数から自動分類する。
/// BookCategory.classify (Phase 2.5e) を再利用し、archive のみ閾値判定で 厚い本/薄い本 を分岐する。
public enum BookTypeClassifier {
    /// bookType の数値 (Stackroom DB 互換):
    /// 0 = 厚い本、1 = 薄い本、2 = 本の一部 (自動判定なし)、3 = 画像セット、4 = テキスト、5 = ムービー
    ///
    /// - Parameter pageCount: 実ページ数。**nil = 信用できるページ数が無い**
    ///   （G26 Codex Minor #2: 破損アーカイブの打ち切り読み。`TruncatedReadPolicy` 参照）。
    ///   nil のとき archive は閾値判定を行わず、自動分類 OFF 時と同じ既定値 0（厚い本）を返す。
    ///   打ち切り読みの 13 ページで「薄い本」と決めつけると、その分類は**永続化され、修復後も
    ///   見直されない** — `books.pages` を書かないのと同じ理由でページ数由来の判定自体を止める。
    ///   ページ数に依存しない分類（動画/テキスト/フォルダ/画像）は nil でも従来どおり働く。
    public static func autoClassify(url: URL, pageCount: Int?, thickThreshold: Int) -> Int {
        let category = BookCategory.classify(path: url.path)
        switch category {
        case .video:  return 5
        case .text:   return 4
        case .folder: return 3
        case .image:  return 3
        case .archive:
            guard let pageCount else { return 0 }
            return pageCount >= thickThreshold ? 0 : 1
        }
    }
}
