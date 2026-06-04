// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

public enum AppError: Error, LocalizedError {
    case databaseOpenFailed(Error)
    case importFailed(ImportError)
    case launchFailed(path: String, reason: String)
    case titleRequired
    case unexpected(Error)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let e):
            return "ライブラリ DB を開けませんでした: \(e.localizedDescription)"
        case .importFailed(let ie):
            return "取り込みに失敗しました: \(ie.localizedDescription)"
        case .launchFailed(let path, let reason):
            return "\"\(path)\"を開けませんでした: \(reason)"
        case .titleRequired:
            return "タイトルは必須項目です"
        case .unexpected(let e):
            return "予期しないエラー: \(e.localizedDescription)"
        }
    }
}
