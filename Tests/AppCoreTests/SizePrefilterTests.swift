// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("DuplicateFinder.idsNeedingHash — size prefilter")
struct SizePrefilterTests {
    @Test func onlySizeCollisionsNeedHash() {
        // size 100: ids 1,2 (collide) / size 200: id 3 (alone) / size 100: id 4 → collides too
        let ids = DuplicateFinder.idsNeedingHash(sizes: [(1, 100), (2, 100), (3, 200), (4, 100)])
        #expect(ids == Set([1, 2, 4]))
    }
    @Test func noCollisionsEmpty() {
        #expect(DuplicateFinder.idsNeedingHash(sizes: [(1, 10), (2, 20)]).isEmpty)
    }
}
