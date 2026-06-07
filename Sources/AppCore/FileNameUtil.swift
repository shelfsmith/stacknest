// SPDX-License-Identifier: MIT
import Foundation

/// ファイルパス関連の小ユーティリティ。
public enum FileNameUtil {
    /// パスの最後の要素から拡張子（最後の 1 つ）を除いた名前を返す。
    /// 例: "/a/b/book01.zip" → "book01" / "/a/b/vol.1.zip" → "vol.1"
    ///     "/a/b/MySet" → "MySet" / "/a/b/MySet/" → "MySet"（末尾スラッシュ正規化）
    public static func withoutExtension(path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return (last as NSString).deletingPathExtension
    }
}
