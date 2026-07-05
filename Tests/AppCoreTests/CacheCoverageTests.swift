// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("CacheCoverage")
struct CacheCoverageTests {
    @Test func mergesContiguousRuns() {
        let segs = CacheCoverage.segments(cached: [0, 1, 2, 5], pageCount: 10)
        #expect(segs.count == 2)
        #expect(segs[0] == 0.0...0.3)   // pages 0..2 → [0/10, 3/10]
        #expect(segs[1] == 0.5...0.6)   // page 5 → [5/10, 6/10]
    }
    @Test func emptyWhenNoCache() {
        #expect(CacheCoverage.segments(cached: [], pageCount: 10).isEmpty)
    }
    @Test func emptyWhenZeroPages() {
        #expect(CacheCoverage.segments(cached: [0, 1], pageCount: 0).isEmpty)
    }
    @Test func singlePage() {
        let segs = CacheCoverage.segments(cached: [3], pageCount: 10)
        #expect(segs == [0.3...0.4])
    }
    @Test func ignoresOutOfRange() {
        let segs = CacheCoverage.segments(cached: [3, 100, -1], pageCount: 10)
        #expect(segs == [0.3...0.4])
    }
    @Test func fullCoverageIsOneSegment() {
        let segs = CacheCoverage.segments(cached: Set(0..<4), pageCount: 4)
        #expect(segs == [0.0...1.0])
    }
}
