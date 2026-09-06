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

    public init(
        title: String, type: Int, icon: Int? = nil,
        itemView: Bool = false, toolTab: Bool = false,
        items: [Int] = [], conditions: PlaylistConditions? = nil,
        conditionsUnreadable: Bool = false
    ) {
        self.title = title; self.type = type; self.icon = icon
        self.itemView = itemView; self.toolTab = toolTab
        self.items = items; self.conditions = conditions
        self.conditionsUnreadable = conditionsUnreadable
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
        self.items    = (try? c.decodeIfPresent([Int].self, forKey: .items)) ?? []
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

    /// Stackroom は真偽値を `<true/>` でも `<integer>1</integer>` でも書く（`BookRecord.unseen` と同じ揺らぎ）。
    private static func flag(
        from c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> Bool {
        if let b = (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
        if let i = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return i >= 1 }
        return false
    }
}
