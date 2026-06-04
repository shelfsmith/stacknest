// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("SidebarItem smartShelf")
struct SidebarItemSmartShelfTests {
    @Test func smartShelfEquatableAndHashable() {
        let a = SidebarItem.smartShelf(id: 1, name: "S")
        let b = SidebarItem.smartShelf(id: 1, name: "S")
        let c = SidebarItem.smartShelf(id: 2, name: "S")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func smartShelfDistinctFromManualShelf() {
        let smart = SidebarItem.smartShelf(id: 1, name: "S")
        let manual = SidebarItem.shelf(id: 1, name: "S", kind: .user)
        #expect(smart != manual)
    }
}
