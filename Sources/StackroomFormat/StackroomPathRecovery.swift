// SPDX-License-Identifier: MIT
import Foundation

/// G49: Stackroom の `Path` キーを持たない本のパスを、`Cover Image Path` から復元する規則。
///
/// Stackroom は初期の登録で `Path` を書かず `Cover Image Path` だけを持つ時期があり、
/// 書庫によっては相当数の本が `Path` を欠く（外部からの報告 PR #2）。
/// 判定はここに閉じ込め、ファイルの実在確認は呼び出し側（取り込み層）が行う。
public enum StackroomPathRecovery {
    public enum Plan: Equatable, Sendable {
        /// 宣言された `Path` をそのまま使う
        case keep
        /// 表紙パスが本そのもの（アーカイブ・PDF・EPUB）を指しているので、それを使う
        case useCoverPath(String)
        /// 表紙パスがフォルダ書籍の中の画像を指しているので、その親ディレクトリを使う。
        /// **呼び出し側は、実在するディレクトリのときだけ採用すること。**
        case useCoverParentDirectory(String)
        /// 手がかりが無い
        case unrecoverable
    }

    /// 本そのものとして扱う拡張子（`BookCategory` の archive ＋ PDF/EPUB に対応）。
    static let bookExtensions: Set<String> = [
        "zip", "cbz", "rar", "cbr", "7z", "cb7", "pdf", "epub",
    ]

    /// フォルダ書籍の中身として扱う拡張子（`CoverRefresher.standaloneImageExtensions` と同じ集合）。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
    ]

    public static func plan(path: String?, coverImagePath: String) -> Plan {
        if let path, !path.isEmpty { return .keep }
        guard !coverImagePath.isEmpty else { return .unrecoverable }
        let ext = (coverImagePath as NSString).pathExtension.lowercased()
        if bookExtensions.contains(ext) {
            return .useCoverPath(coverImagePath)
        }
        if imageExtensions.contains(ext) {
            let parent = (coverImagePath as NSString).deletingLastPathComponent
            // 相対パス・ルート直下は親を採らない（掴む先が定まらない）
            guard parent.hasPrefix("/"), parent != "/" else { return .unrecoverable }
            return .useCoverParentDirectory(parent)
        }
        return .unrecoverable
    }
}
