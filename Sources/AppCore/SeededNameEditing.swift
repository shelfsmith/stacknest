// SPDX-License-Identifier: MIT
import Foundation

/// G56-S1: 種まきの既定名（プリセットの「既定」・共有トークンの「(既定) 閲覧」など）の編集欄。
/// 保存値は言語に依らない日本語の種のまま。欄に出すときだけ表示名にし、欄が表示名のまま変わっていなければ
/// 元の保存値に戻す（英語の画面で開いて閉じただけで保存値が "Default" に書き換わらないように）。
public enum SeededNameEditing {
    public static func fieldText(stored: String, display: (String) -> String) -> String {
        display(stored)
    }

    /// `original` は欄を開いたときの保存値（入力中に書き換わる値ではない）。
    public static func storedValue(field: String, original: String, display: (String) -> String) -> String {
        field == display(original) ? original : field
    }
}
