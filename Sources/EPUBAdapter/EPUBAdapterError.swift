// SPDX-License-Identifier: MIT
import Foundation

public enum EPUBAdapterError: Error, Equatable, Sendable, LocalizedError {
    /// 実装側のエラー文言をそのまま持つ（型は外に漏らさない）。
    case cannotOpen(String)

    /// G48-2 最終レビュー B: `LocalizedError` に適合していないと `AppError.unexpected(_:)` の
    /// `errorDescription` は `error.localizedDescription`（既定実装＝型名だけの
    /// 「予期しないエラー: … error 0.」）に落ち、`cannotOpen` が持つ理由が消えてしまう。
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let reason): return "EPUB を開けません: \(reason)"
        }
    }
}
