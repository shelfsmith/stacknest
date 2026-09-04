// SPDX-License-Identifier: MIT
import Testing
import LibraryStore
import EPUBAdapter
@testable import AppCore

@Suite("EPUB の綴じ方向 → 本の綴じ方向")
struct EPUBPageDirectionMappingTests {
    @Test func rtl() { #expect(EPUBPageDirectionMapping.pageDirection(from: .rtl) == .rightToLeft) }
    @Test func ltr() { #expect(EPUBPageDirectionMapping.pageDirection(from: .ltr) == .leftToRight) }
    @Test("不明なら書かない") func unknown() { #expect(EPUBPageDirectionMapping.pageDirection(from: .unknown) == nil) }
}
