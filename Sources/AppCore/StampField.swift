// SPDX-License-Identifier: MIT
import Foundation

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
        case .genre:    return String(localized: "ジャンル")
        case .neta:     return String(localized: "関連")
        case .keywordA: return String(localized: "キーワード A")
        case .keywordB: return String(localized: "キーワード B")
        case .keywordC: return String(localized: "キーワード C")
        }
    }
}
