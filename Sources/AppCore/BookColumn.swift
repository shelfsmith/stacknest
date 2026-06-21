// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI

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

    public var localizedTitle: LocalizedStringKey {
        switch self {
        case .title:     return "タイトル"
        case .rating:    return "レート"
        case .author:    return "作者"
        case .genre:     return "ジャンル"
        case .dateAdded: return "登録日"
        case .playDate:  return "読んだ日"
        case .unseen:    return "未読"
        case .bookType:  return "種類"
        case .neta:      return "関連"
        case .keywordA:  return "キーワード A"
        case .keywordB:  return "キーワード B"
        case .keywordC:  return "キーワード C"
        case .memo:      return "メモ"
        case .series:    return "シリーズ"
        case .volume:    return "巻数"
        }
    }

    /// Plain string version of the column title (for AppKit NSTableColumn.title).
    /// Uses String(localized:) for runtime localization.
    public var localizedTitleString: String {
        switch self {
        case .title:     return String(localized: "タイトル")
        case .rating:    return String(localized: "レート")
        case .author:    return String(localized: "作者")
        case .genre:     return String(localized: "ジャンル")
        case .dateAdded: return String(localized: "登録日")
        case .playDate:  return String(localized: "読んだ日")
        case .unseen:    return String(localized: "未読")
        case .bookType:  return String(localized: "種類")
        case .neta:      return String(localized: "関連")
        case .keywordA:  return String(localized: "キーワード A")
        case .keywordB:  return String(localized: "キーワード B")
        case .keywordC:  return String(localized: "キーワード C")
        case .memo:      return String(localized: "メモ")
        case .series:    return String(localized: "シリーズ")
        case .volume:    return String(localized: "巻数")
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
