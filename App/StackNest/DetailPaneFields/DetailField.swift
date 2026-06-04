// SPDX-License-Identifier: MIT
import Foundation

/// Field identity for Tab navigation in the detail pane.
enum DetailField: Hashable {
    case title, author, keywordA, keywordB, keywordC, genre, neta, series, volume, memo

    /// The next field in Tab order. Wraps around to .title at the end.
    var next: DetailField {
        switch self {
        case .title:    return .author
        case .author:   return .keywordA
        case .keywordA: return .keywordB
        case .keywordB: return .keywordC
        case .keywordC: return .genre
        case .genre:    return .neta
        case .neta:     return .series
        case .series:   return .volume
        case .volume:   return .memo
        case .memo:     return .title
        }
    }

    /// The previous field in Shift+Tab order. Wraps around to .memo at the start.
    var previous: DetailField {
        switch self {
        case .title:    return .memo
        case .author:   return .title
        case .keywordA: return .author
        case .keywordB: return .keywordA
        case .keywordC: return .keywordB
        case .genre:    return .keywordC
        case .neta:     return .genre
        case .series:   return .neta
        case .volume:   return .series
        case .memo:     return .volume
        }
    }
}
