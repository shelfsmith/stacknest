// SPDX-License-Identifier: MIT

/// 1 つの日本語キーに対する英語の訳。単複を持つものは `one`／`other`。
public struct L10nEntry: Sendable {
    public let en: String
    public let enPlural: (one: String, other: String)?
    public init(_ en: String) { self.en = en; self.enPlural = nil }
    public init(one: String, other: String) { self.en = other; self.enPlural = (one, other) }
}

/// 単位ごとの辞書を束ねる。段 1 の各単位は `Tables/L10n+<Unit>.swift` に
/// `extension L10nTable { static let <unit>: [String: L10nEntry] = [...] }` を置き、ここの `parts` に 1 行足す。
public enum L10nTable {
    static let parts: [[String: L10nEntry]] = [
        core,
    ]

    public static let all: [String: L10nEntry] = {
        var merged: [String: L10nEntry] = [:]
        for p in parts { merged.merge(p) { first, _ in first } }
        return merged
    }()

    /// 2 つ以上の単位に同じキーがあるもの（テストで空であることを検査する）。
    public static let duplicateKeys: [String] = {
        var seen: Set<String> = [], dups: Set<String> = []
        for p in parts { for k in p.keys where !seen.insert(k).inserted { dups.insert(k) } }
        return dups.sorted()
    }()
}
