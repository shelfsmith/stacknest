// SPDX-License-Identifier: MIT
import Foundation

extension BookColumn {
    /// ヘッダクリックソートで使うサーバ sort キー文字列。playDate→lastRead。
    public var serverSortKey: String {
        switch self {
        case .title:     return "title"
        case .rating:    return "rating"
        case .author:    return "author"
        case .genre:     return "genre"
        case .dateAdded: return "dateAdded"
        case .playDate:  return "lastRead"
        case .unseen:    return "unseen"
        case .bookType:  return "bookType"
        case .neta:      return "neta"
        case .keywordA:  return "keywordA"
        case .keywordB:  return "keywordB"
        case .memo:      return "memo"
        case .series:    return "series"
        case .volume:    return "volume"
        }
    }

    /// この列を出すためにサーバへ追加要求すべき wire フィールド名。基本フィールドは nil。
    public var wireField: String? {
        switch self {
        case .genre:    return "genre"
        case .neta:     return "neta"
        case .keywordA: return "keywordA"
        case .keywordB: return "keywordB"
        case .memo:     return "memo"
        default:        return nil
        }
    }
}

/// 表示中の列集合から、サーバへ要求する追加フィールド集合を求める。
public enum RemoteListFields {
    public static func fields(for columns: Set<BookColumn>) -> Set<String> {
        Set(columns.compactMap { $0.wireField })
    }
}
