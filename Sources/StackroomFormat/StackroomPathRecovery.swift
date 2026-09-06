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

    /// フォルダ書籍の中身として扱う拡張子。
    /// （`CoverRefresher.standaloneImageExtensions` と同じ内容だが、あちらは AppCore の private で、
    /// StackroomFormat からは層をまたげないため独立して持つ。片方を変えたらもう片方も見ること。）
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
    ]

    /// Stackroom の `File Type` のうち、確実に**単一ファイルのアーカイブ**を指す値。
    /// 実書庫では 2（zip）がほぼすべてで、3 は 1 件のみ確認され意味が確定していない。
    /// **確定していない値はアーカイブ側に寄せる**（フォルダと誤って推定してディレクトリを掴むより、
    /// 復元しないほうが安全。パスが空の本はリンク切れとして relink で直せる）。
    static let archiveFileTypes: Set<Int> = [2, 3, 5]

    /// - Parameters:
    ///   - fileType: Stackroom の `File Type`。アーカイブと分かっている本では、表紙が画像を指していても
    ///     その親ディレクトリを本の場所とはみなさない（実書庫に、zip の本の表紙が別フォルダの画像を
    ///     指している例がある）。
    public static func plan(path: String?, coverImagePath: String, fileType: Int) -> Plan {
        if let path, !path.isEmpty { return .keep }
        // 相対パスは本の場所として使えない（開く・表示する・relink がすべて絶対パス前提）。
        guard coverImagePath.hasPrefix("/") else { return .unrecoverable }
        let ext = (coverImagePath as NSString).pathExtension.lowercased()
        if bookExtensions.contains(ext) {
            return .useCoverPath(coverImagePath)
        }
        if imageExtensions.contains(ext), !archiveFileTypes.contains(fileType) {
            let parent = (coverImagePath as NSString).deletingLastPathComponent
            // ルート直下は親を採らない（掴む先が定まらない）
            guard parent.hasPrefix("/"), parent != "/" else { return .unrecoverable }
            return .useCoverParentDirectory(parent)
        }
        return .unrecoverable
    }
}
