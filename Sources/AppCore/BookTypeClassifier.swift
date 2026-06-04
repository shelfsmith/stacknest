// SPDX-License-Identifier: MIT
import Foundation

/// B18 (Phase 2.5g): 新規追加 book の bookType (Stackroom int) を URL + 画像数から自動分類する。
/// BookCategory.classify (Phase 2.5e) を再利用し、archive のみ閾値判定で 厚い本/薄い本 を分岐する。
public enum BookTypeClassifier {
    /// bookType の数値 (Stackroom DB 互換):
    /// 0 = 厚い本、1 = 薄い本、2 = 本の一部 (自動判定なし)、3 = 画像セット、4 = テキスト、5 = ムービー
    public static func autoClassify(url: URL, pageCount: Int, thickThreshold: Int) -> Int {
        let category = BookCategory.classify(path: url.path)
        switch category {
        case .video:  return 5
        case .text:   return 4
        case .folder: return 3
        case .image:  return 3
        case .archive:
            return pageCount >= thickThreshold ? 0 : 1
        }
    }
}
