// SPDX-License-Identifier: MIT
import Foundation
import StackNestL10n

public enum StampField: String, CaseIterable, Sendable {
    case genre
    case neta
    case keywordA = "keywordA"
    case keywordB = "keywordB"
    case keywordC = "keywordC"

    public var dbColumn: String {
        switch self {
        case .genre:    return "genre"
        case .neta:     return "neta"
        case .keywordA: return "keyword_a"
        case .keywordB: return "keyword_b"
        case .keywordC: return "keyword_c"
        }
    }

    public var localizedTitle: String {
        switch self {
        case .genre:    return L10n.text("ジャンル")
        case .neta:     return L10n.text("関連")
        case .keywordA: return L10n.text("キーワード A")
        case .keywordB: return L10n.text("キーワード B")
        case .keywordC: return L10n.text("キーワード C")
        }
    }
}
