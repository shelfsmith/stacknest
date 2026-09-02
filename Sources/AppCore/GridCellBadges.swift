// SPDX-License-Identifier: MIT
import Foundation

/// G45/G46: グリッドセルに重ねる印の判断。見た目（SwiftUI）から切り離してテストで固定する。
public struct GridCellBadges: Equatable, Sendable {
    /// 左上のハート
    public let showFavorite: Bool
    /// 右下の緑丸。**未読のときだけ**。既読で空丸は出さない（表紙を汚さない）。
    public let showUnseen: Bool

    public static func derive(favorited: Bool, unseen: Bool) -> GridCellBadges {
        GridCellBadges(showFavorite: favorited, showUnseen: unseen)
    }
}

/// 著者行に出す文字列。nil / 空でも**空文字**を返す。
/// `lineLimit(1, reservesSpace: true)` と組で使い、著者の無い本だけセルが低くなるのを防ぐ
/// （低くなると LazyVGrid が行内で縦中央寄せし、上端がずれて見える —— タイトルで直したのと同じ問題）。
public func gridAuthorLine(_ author: String?) -> String {
    author ?? ""
}
