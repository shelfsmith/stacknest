// SPDX-License-Identifier: MIT
import Foundation

/// 監視フォルダのスキャン補助（純ロジック・I/O は呼び出し側）。
public enum WatchFolderScanner {
    private static let transientExtensions: Set<String> = ["part", "crdownload", "download", "tmp"]

    /// ダウンロード中・一時ファイルか判定する。隠しファイル（`.` 始まり）も一時扱い。
    public static func isTransient(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        return transientExtensions.contains(url.pathExtension.lowercased())
    }

    /// トップレベル URL 群から取り込み候補を絞り込む。
    /// - 一時ファイルを除外
    /// - ライブラリ既存パスを除外
    /// - ベースラインパスを除外
    public static func importable(topLevel: [URL],
                                  existingLibraryPaths: Set<String>,
                                  baseline: Set<String>) -> [URL] {
        topLevel.filter { url in
            !isTransient(url)
                && !existingLibraryPaths.contains(url.path)
                && !baseline.contains(url.path)
        }
    }

    /// ファイルサイズの前回観測値と今回観測値を比較し、安定（サイズ不変）かどうかを判定する。
    /// - 2 回連続で同一サイズならそのパスを安定とみなす（ダウンロード完了と判断）。
    /// - Returns: `stable`（確定 path の昇順配列）と `pending`（次回比較用のサイズマップ）
    public static func decideStable(previous: [String: Int64],
                                    current: [String: Int64]) -> (stable: [String], pending: [String: Int64]) {
        var stable: [String] = []
        var pending: [String: Int64] = [:]
        for (path, size) in current {
            if let prev = previous[path], prev == size { stable.append(path) }
            else { pending[path] = size }
        }
        return (stable.sorted(), pending)
    }
}
