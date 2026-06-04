// SPDX-License-Identifier: MIT
import Foundation

public struct FilterState: Codable, Sendable, Equatable {
    public var bookTypes: Set<Int> = []
    public var unseen: UnseenMode? = nil
    public enum UnseenMode: Int, Codable, Sendable {
        case unreadOnly = 0
        case readOnly = 1
    }
    public var ratingMin: Int? = nil
    public var dateAdded: DateRangeCondition? = nil
    public var playDate: DateRangeCondition? = nil

    // Text facet filters (multi-value aware: partial match against ", "-delimited stored values)
    public var genres: Set<String> = []
    public var serieses: Set<String> = []
    public var authors: Set<String> = []
    public var netas: Set<String> = []
    public var keywordAs: Set<String> = []
    public var keywordBs: Set<String> = []
    public var keywordCs: Set<String> = []

    public struct DateRangeCondition: Codable, Sendable, Equatable {
        public var direction: Direction
        public var days: Int
        public enum Direction: String, Codable, Sendable {
            case within
            case olderThan
        }
        public init(direction: Direction, days: Int) {
            self.direction = direction
            self.days = max(1, days)
        }
    }

    public init() {}

    public var isEmpty: Bool {
        bookTypes.isEmpty
            && unseen == nil
            && ratingMin == nil
            && dateAdded == nil
            && playDate == nil
            && genres.isEmpty
            && serieses.isEmpty
            && authors.isEmpty
            && netas.isEmpty
            && keywordAs.isEmpty
            && keywordBs.isEmpty
            && keywordCs.isEmpty
    }

    public var activeCount: Int {
        var n = 0
        if !bookTypes.isEmpty { n += 1 }
        if unseen != nil { n += 1 }
        if ratingMin != nil { n += 1 }
        if dateAdded != nil { n += 1 }
        if playDate != nil { n += 1 }
        if !genres.isEmpty { n += 1 }
        if !serieses.isEmpty { n += 1 }
        if !authors.isEmpty { n += 1 }
        if !netas.isEmpty { n += 1 }
        if !keywordAs.isEmpty { n += 1 }
        if !keywordBs.isEmpty { n += 1 }
        if !keywordCs.isEmpty { n += 1 }
        return n
    }

    /// 指定フィールドの selected set を values で上書き。他フィールドの selection は維持。
    /// fieldName は BrowserPaneState.BrowseField の case 名
    /// ("genre", "series", "author", "neta", "keywordA", "keywordB", "keywordC")。
    /// 未知の fieldName は noop。
    public mutating func replaceSelection(for fieldName: String, with values: Set<String>) {
        switch fieldName {
        case "genre":    genres    = values
        case "series":   serieses  = values
        case "author":   authors   = values
        case "neta":     netas     = values
        case "keywordA": keywordAs = values
        case "keywordB": keywordBs = values
        case "keywordC": keywordCs = values
        default: break
        }
    }
}
