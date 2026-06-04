// SPDX-License-Identifier: MIT
import Foundation

/// HelperLauncher が viewer 選択に使う file category。
/// B18 (bookType 自動分類, Phase 2.5f) の DB 属性とは目的が異なるため独立 enum。
public enum BookCategory: String, CaseIterable, Codable, Sendable {
    case archive, image, folder, video, text

    /// UI 表示用ラベル (Settings 画面)
    public var displayName: String {
        switch self {
        case .archive: return "アーカイブ"
        case .image:   return "画像"
        case .folder:  return "フォルダ"
        case .video:   return "動画"
        case .text:    return "テキスト"
        }
    }

    /// UI 補足表示 (拡張子例)
    public var extensionsHint: String {
        switch self {
        case .archive: return ".zip / .cbz / .rar / .cbr / .7z"
        case .image:   return ".jpg / .png / .gif / .webp / .heic / etc"
        case .folder:  return "(ディレクトリ書籍)"
        case .video:   return ".mp4 / .mov / .avi / .mkv / .webm / .m4v"
        case .text:    return ".pdf / .epub / .txt / .md / .rtf"
        }
    }

    /// path をもとに category を判定。
    /// folder 判定は FileManager.fileExists(atPath:isDirectory:) の boolValue を見る。
    /// 未知拡張子は .archive に倒す (Stackroom が zip 中心だった経緯による fallback)。
    public static func classify(path: String) -> BookCategory {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return .folder
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "cbz", "rar", "cbr", "7z", "cb7":
            return .archive
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif":
            return .image
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return .video
        case "pdf", "epub", "txt", "md", "rtf":
            return .text
        default:
            return .archive
        }
    }

    /// Phase 2.5g+h+i fixup v1: NSOpenPanel / DropDelegate などの caller が「対応拡張子」を
    /// 単一ソースから引けるように。`classify` の switch case と同じセットで、default の
    /// archive fallback は含まない (= 真に「対応している」拡張子のみ)。
    public static let supportedExtensions: Set<String> = [
        "zip", "cbz", "cbr", "rar", "7z", "cb7",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
        "mp4", "mov", "avi", "mkv", "webm", "m4v",
        "pdf", "epub", "txt", "md", "rtf"
    ]
}

/// CodingKeyRepresentable で String dict として encode させる (JSONEncoder の object 形式を強制)。
/// これがないと `[BookCategory: String]` は unkeyed array (`["archive","/path",...]`) で encode される。
extension BookCategory: CodingKeyRepresentable {}
