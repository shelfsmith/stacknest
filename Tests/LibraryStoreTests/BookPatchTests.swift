// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryStore

@Suite("BookPatch")
struct BookPatchTests {
    @Test func emptyPatchIsEmpty() {
        let p = BookPatch()
        #expect(p.isEmpty)
    }

    @Test func patchWithOneFieldIsNotEmpty() {
        var p = BookPatch()
        p.title = "x"
        #expect(!p.isEmpty)
    }

    @Test func patchWithRatingZeroIsNotEmpty() {
        var p = BookPatch()
        p.rating = 0
        #expect(!p.isEmpty)
    }
}
