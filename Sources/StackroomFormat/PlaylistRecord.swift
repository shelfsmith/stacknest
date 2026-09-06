// SPDX-License-Identifier: MIT
import Foundation

/// G49: `Decodable` のみ（`Codable` から狭めた）。`conditionsUnreadable` は XML には無い
/// 「読めなかった」という判定結果で、`CodingKeys` にも入らない。エンコードできてしまうと
/// 再エンコードで黙って落ちるため、そもそもエンコードさせない。
/// DB への保存は `Database.insertPlaylist` が列ごとに書いており、この型を丸ごと符号化はしない。
public struct PlaylistRecord: Decodable, Sendable {
    public let title: String
    public let type: Int
    public let icon: Int?
    public let itemView: Bool
    public let toolTab: Bool
    public let items: [Int]
    public let conditions: PlaylistConditions?
    /// G49: `Conditions` キーはあったがデコードできなかった（スマートシェルフの条件が破損している）ことの記録。
    public let conditionsUnreadable: Bool
    /// G49: `Items` の一部（または全部）が読めず、棚の中身が欠けたことの記録。
    /// 空の `Items` と「読めなかった `Items`」を取り違えないために持つ。
    public let itemsUnreadable: Bool

    public init(
        title: String, type: Int, icon: Int? = nil,
        itemView: Bool = false, toolTab: Bool = false,
        items: [Int] = [], conditions: PlaylistConditions? = nil,
        conditionsUnreadable: Bool = false, itemsUnreadable: Bool = false
    ) {
        self.title = title; self.type = type; self.icon = icon
        self.itemView = itemView; self.toolTab = toolTab
        self.items = items; self.conditions = conditions
        self.conditionsUnreadable = conditionsUnreadable
        self.itemsUnreadable = itemsUnreadable
    }

    public enum CodingKeys: String, CodingKey {
        case title       = "Title"
        case type        = "Type"
        case icon        = "Icon"
        case itemView    = "ItemView"
        case toolTab     = "ToolTab"
        case items       = "Items"
        case conditions  = "Conditions"
    }

    // 補足（G49 レビュー）: `type` は DB の `playlist.type` に書かれるが、スマートシェルフかどうかの
    // 判定は `conditions IS NOT NULL` で行われる（`Database.swift`）。つまり `Type` が欠けていても
    // 挙動は変わらない。スマートシェルフが普通のシェルフに落ちるのは `conditions` が読めなかった
    // ときで、それは `conditionsUnreadable` として必ず警告に出る。

    // Stackroom の一部プレイリストは ItemView / ToolTab / Items / Type キーを持たない。
    // 欠落しても安全なデフォルト値（false / [] / 0）を使うカスタム init。
    // ItemView / ToolTab は真偽値でも整数（0/1）でも書かれることがある（`BookRecord.unseen` と同じ揺らぎ）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.type = (try? c.decodeIfPresent(Int.self, forKey: .type)) ?? 0
        self.icon = (try? c.decodeIfPresent(Int.self, forKey: .icon)) ?? nil
        self.itemView = Self.flag(from: c, forKey: .itemView)
        self.toolTab  = Self.flag(from: c, forKey: .toolTab)
        let items = Self.items(from: c)
        self.items = items.values
        self.itemsUnreadable = items.dropped
        if c.contains(.conditions) {
            if let decoded = try? c.decodeIfPresent(PlaylistConditions.self, forKey: .conditions) {
                self.conditions = decoded
                self.conditionsUnreadable = false
            } else {
                self.conditions = nil
                self.conditionsUnreadable = true
            }
        } else {
            self.conditions = nil
            self.conditionsUnreadable = false
        }
    }

    /// `Items` を 1 要素ずつ読む。まるごと `try?` にすると、1 個でも整数でない要素があった時点で
    /// **棚の中身が全部消える**（今回直している「1 個で全滅」と同じ形）。読める分は残し、
    /// 落ちた分があったことは `itemsUnreadable` で必ず伝える。
    private static func items(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> (values: [Int], dropped: Bool) {
        guard c.contains(.items) else { return ([], false) }
        if let whole = (try? c.decodeIfPresent([Int].self, forKey: .items)) ?? nil {
            return (whole, false)
        }
        guard var array = try? c.nestedUnkeyedContainer(forKey: .items) else {
            return ([], true)   // Items はあるのに配列ですらない
        }
        var values: [Int] = []
        var dropped = false
        while !array.isAtEnd {
            // 常に成功するラッパで確実に 1 要素進める（LibraryDocument の Playlists と同じ理由）。
            guard let entry = try? array.decode(FailableInt.self) else { break }
            if let value = entry.value { values.append(value) } else { dropped = true }
        }
        return (values, dropped)
    }

    /// 整数として読めなければ nil になるだけで、決して throw しない要素。
    private struct FailableInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Int.self)
        }
    }

    /// Stackroom は真偽値を `<true/>` でも `<integer>1</integer>` でも書く（`BookRecord.unseen` と同じ揺らぎ）。
    private static func flag(
        from c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> Bool {
        if let b = (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
        if let i = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return i >= 1 }
        return false
    }
}
