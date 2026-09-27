// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import StackNestL10n

public enum AppError: Error, LocalizedError {
    case databaseOpenFailed(Error)
    case importFailed(ImportError)
    case launchFailed(path: String, reason: String)
    case titleRequired
    case unexpected(Error)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let e):
            return L10n.format("ライブラリ DB を開けませんでした: %@", e.localizedDescription)
        case .importFailed(let ie):
            return L10n.format("取り込みに失敗しました: %@", ie.localizedDescription)
        case .launchFailed(let path, let reason):
            return L10n.format("\"%@\"を開けませんでした: %@", path, reason)
        case .titleRequired:
            return L10n.text("タイトルは必須項目です")
        case .unexpected(let e):
            return L10n.format("予期しないエラー: %@", e.localizedDescription)
        }
    }
}
