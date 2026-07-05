// SPDX-License-Identifier: MIT
import Foundation

/// 表紙ソースの識別。coverImageName の意味: nil=自動(先頭ページ) / "<entry>"=アーカイブ内ページ / "@external"=外部画像。
/// 外部表紙は Thumbnails/<bookID>/thumbnail.jpg が外部画像そのもの（アーカイブ再抽出で上書きしない）。
public enum CoverSource {
    public static let externalSentinel = "@external"
    public static func isExternal(_ coverImageName: String?) -> Bool { coverImageName == externalSentinel }
}
