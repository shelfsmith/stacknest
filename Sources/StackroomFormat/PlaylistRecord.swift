// SPDX-License-Identifier: MIT
import Foundation

public struct PlaylistRecord: Codable, Sendable {
    public let title: String
    public let type: Int
    public let icon: Int?
    public let itemView: Bool
    public let toolTab: Bool
    public let items: [Int]
    public let conditions: PlaylistConditions?

    public init(
        title: String, type: Int, icon: Int? = nil,
        itemView: Bool = false, toolTab: Bool = false,
        items: [Int] = [], conditions: PlaylistConditions? = nil
    ) {
        self.title = title; self.type = type; self.icon = icon
        self.itemView = itemView; self.toolTab = toolTab
        self.items = items; self.conditions = conditions
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

    // Stackroom の一部プレイリストは ItemView / ToolTab / Items キーを持たない。
    // 欠落しても安全なデフォルト値（false / []）を使うカスタム init。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title      = try  c.decode(String.self, forKey: .title)
        self.type       = try  c.decode(Int.self,    forKey: .type)
        self.icon       = try  c.decodeIfPresent(Int.self,  forKey: .icon)
        self.itemView   = (try? c.decodeIfPresent(Bool.self, forKey: .itemView)) ?? false
        self.toolTab    = (try? c.decodeIfPresent(Bool.self, forKey: .toolTab))  ?? false
        self.items      = (try? c.decodeIfPresent([Int].self, forKey: .items))   ?? []
        self.conditions = try? c.decodeIfPresent(PlaylistConditions.self, forKey: .conditions) ?? nil
    }
}
