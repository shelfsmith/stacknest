// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite struct SidebarItemTests {
    @Test func equality() {
        #expect(SidebarItem.library == SidebarItem.library)
        #expect(SidebarItem.favorites == SidebarItem.favorites)
        #expect(SidebarItem.recent == SidebarItem.recent)
        #expect(SidebarItem.shelf(id: 1, name: "A", kind: .user) == SidebarItem.shelf(id: 1, name: "A", kind: .user))
        #expect(SidebarItem.shelf(id: 1, name: "A", kind: .user) != SidebarItem.shelf(id: 2, name: "A", kind: .user))
        #expect(SidebarItem.shelf(id: 1, name: "A", kind: .user) != SidebarItem.shelf(id: 1, name: "B", kind: .user))
    }

    @Test func hashable() {
        let s: Set<SidebarItem> = [.library, .favorites, .recent, .shelf(id: 1, name: "A", kind: .user)]
        #expect(s.count == 4)
    }
}
