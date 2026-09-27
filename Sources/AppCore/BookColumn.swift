// SPDX-License-Identifier: MIT
import Foundation
import StackNestL10n

public enum BookColumn: String, Codable, CaseIterable, Sendable, Hashable {
    case title
    case rating
    case author
    case genre
    case dateAdded = "date_added"
    case playDate = "play_date"
    case unseen
    case bookType = "book_type"
    case neta
    case keywordA = "keyword_a"
    case keywordB = "keyword_b"
    case keywordC = "keyword_c"
    case memo
    case series
    case volume

    /// Title column cannot be hidden — always visible in list view.
    public var alwaysVisible: Bool { self == .title }

    /// Whether this column is shown by default before user customization.
    public var defaultEnabled: Bool {
        switch self {
        case .title, .rating, .author, .genre, .dateAdded, .playDate: return true
        default: return false
        }
    }

    /// Plain string version of the column title (for AppKit NSTableColumn.title).
    /// Uses `L10n.text` (StackNestL10n) for runtime localization.
    public var localizedTitleString: String {
        switch self {
        case .title:     return L10n.text("タイトル")
        case .rating:    return L10n.text("レート")
        case .author:    return L10n.text("作者")
        case .genre:     return L10n.text("ジャンル")
        case .dateAdded: return L10n.text("登録日")
        case .playDate:  return L10n.text("読んだ日")
        case .unseen:    return L10n.text("未読")
        case .bookType:  return L10n.text("種類")
        case .neta:      return L10n.text("関連")
        case .keywordA:  return L10n.text("キーワード A")
        case .keywordB:  return L10n.text("キーワード B")
        case .keywordC:  return L10n.text("キーワード C")
        case .memo:      return L10n.text("メモ")
        case .series:    return L10n.text("シリーズ")
        case .volume:    return L10n.text("巻数")
        }
    }

    /// Default initial column width in pixels.
    public var defaultWidth: CGFloat {
        switch self {
        case .title:     return 200
        case .rating:    return 80
        case .author:    return 150
        case .genre:     return 100
        case .dateAdded: return 100
        case .playDate:  return 100
        case .unseen:    return 40
        case .bookType:  return 80
        case .neta:      return 100
        case .keywordA:  return 100
        case .keywordB:  return 100
        case .keywordC:  return 100
        case .memo:      return 200
        case .series:    return 120
        case .volume:    return 60
        }
    }
}
