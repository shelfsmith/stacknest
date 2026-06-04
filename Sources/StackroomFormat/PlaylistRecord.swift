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
}
