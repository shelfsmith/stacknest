// SPDX-License-Identifier: MIT
import Foundation

/// 上書きラベルが非空ならそれを、空文字 / nil なら正準デフォルトを返す純関数。
/// フィールド/bookType ラベルのカスタマイズ（A22/A23）で表示名を解決する中核。
public func effectiveLabel(default defaultLabel: String, override: String?) -> String {
    guard let override, !override.isEmpty else { return defaultLabel }
    return override
}
