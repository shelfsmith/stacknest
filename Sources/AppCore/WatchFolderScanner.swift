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

    /// 監視フォルダ直下の取り込み候補 URL を列挙する（G9b: 3-way）。
    /// - `.topLevelOnly`（ignore）: 直下の**ファイルのみ**（サブフォルダは無視・候補に出ない＝漏れ修正）。
    /// - `.archive`: 直下の**サブフォルダ各1つ**（=1冊のフォルダ本）＋直下の素ファイルも候補。孫には降りない。
    /// - `.recurse`: 全階層の**ファイル**を個別候補として列挙（従来どおり。ディレクトリ自体は候補にしない）。
    ///
    /// 全モード共通で `.skipsHiddenFiles` によりドットファイル・隠しディレクトリは候補に出ない
    /// （`isTransient` 側のドット判定と二重防御）。シンボリックリンクは `FileManager` の既定挙動どおり
    /// リンクそのものの URL として列挙され、リンク先へは辿らない（isDirectory はリンク先ではなくリンク
    /// 自体の種別を見るため、ディレクトリへのシンボリックリンクは isDir=true 扱いになりうる）。
    public static func enumerateCandidates(folder: URL, mode: WatchedFolder.SubfolderMode) -> [URL] {
        let fm = FileManager.default
        switch mode {
        case .recurse:
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var out: [URL] = []
            for case let url as URL in en {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir { out.append(url) }
            }
            return out
        case .topLevelOnly, .archive:
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
            var out: [URL] = []
            for url in items {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if mode == .archive { out.append(url) }   // archive のみディレクトリを1冊候補に
                    // topLevelOnly はディレクトリを捨てる＝漏れ修正
                } else {
                    out.append(url)                            // 両モードとも直下ファイルは候補
                }
            }
            return out
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
