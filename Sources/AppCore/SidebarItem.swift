// SPDX-License-Identifier: MIT
import Foundation

/// Represents the currently-selected item in the browser sidebar.
public enum SidebarItem: Hashable, Sendable {
    case library
    case favorites
    case recent
    case shelf(id: Int64, name: String, kind: ShelfKind)
    case smartShelf(id: Int64, name: String)

    public enum ShelfKind: Sendable, Hashable {
        case user
        case imported
    }
}
