// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("DuplicateFinder — exact + possible grouping")
struct DuplicateFinderTests {
    private func book(_ id: Int, hash: String? = nil, series: String? = nil, volume: Double? = nil) -> BookRow {
        BookRow(
            id: id, title: "B\(id)", author: nil, genre: nil, path: "/tmp/\(id)",
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil, series: series, volume: volume, coverImageName: nil,
            coverCropRect: nil, pageDirection: nil, contentHash: hash, fileSize: nil, fileMtime: nil
        )
    }

    @Test func exactGroupsByHashCountTwoPlus() {
        let books = [book(1, hash: "h1"), book(2, hash: "h1"), book(3, hash: "h2"), book(4, hash: nil)]
        let groups = DuplicateFinder.findExact(books)
        #expect(groups.count == 1)
        #expect(groups.first?.key == "exact:h1")
        #expect(groups.first?.members.map(\.id) == [1, 2])
    }

    @Test func exactIgnoresNilOrEmptyHash() {
        let books = [book(1, hash: nil), book(2, hash: ""), book(3, hash: "")]
        #expect(DuplicateFinder.findExact(books).isEmpty)   // "" は対象外
    }

    @Test func possibleRequiresBothSeriesAndVolume() {
        let books = [
            book(1, series: "S", volume: 1), book(2, series: "S", volume: 1),  // group
            book(3, series: "S", volume: 2),                                   // alone
            book(4, series: "", volume: 1), book(5, series: "X", volume: nil)  // excluded
        ]
        let groups = DuplicateFinder.findPossible(books)
        #expect(groups.count == 1)
        #expect(groups.first?.members.map(\.id) == [1, 2])
    }

    @Test func possibleDoesNotCrashOnNonFiniteOrHugeVolume() {
        // Regression: canonicalVolume(_:) called Int(v) unconditionally for any
        // integral-valued Double, trapping on non-finite or out-of-Int-range values.
        // VolumeEditorField commits bare Double(trimmed), so e.g. "inf" or 1e21 reach here.
        let huge = Double("999999999999999999999")!   // 1e21, integral, > Int.max
        let books = [
            book(1, series: "S", volume: huge), book(2, series: "S", volume: huge),  // group
            book(3, series: "T", volume: .infinity), book(4, series: "T", volume: .infinity),  // group
            book(5, series: "U", volume: -.infinity), book(6, series: "U", volume: -.infinity),  // group
            book(7, series: "V", volume: .nan)  // nan never equals itself → alone, must not crash
        ]
        let groups = DuplicateFinder.findPossible(books)
        #expect(groups.count == 3)   // S/huge, T/inf, U/-inf each have 2 members
        // groups(_:ignoring:) also iterates these rows; must not abort.
        let r = DuplicateFinder.groups(books, ignoring: [])
        #expect(r.possible.count == 3)
    }

    @Test func canonicalVolumeFallsBackForNonFiniteAndHuge() {
        #expect(DuplicateFinder.canonicalVolume(1) == "1")
        #expect(DuplicateFinder.canonicalVolume(1.5) == "1.5")
        #expect(DuplicateFinder.canonicalVolume(.infinity) == String(Double.infinity))
        #expect(DuplicateFinder.canonicalVolume(-.infinity) == String(-Double.infinity))
        let huge = Double("999999999999999999999")!
        #expect(DuplicateFinder.canonicalVolume(huge) == String(huge))
        // Boundary: Double(Int.max) rounds up to 2^63 (Int.max+1) → must NOT call Int(v).
        let intMaxAsDouble = Double(Int.max)
        #expect(DuplicateFinder.canonicalVolume(intMaxAsDouble) == String(intMaxAsDouble))
        // Double(Int.min) == -2^63 is exactly representable and Int(-2^63) is valid.
        #expect(DuplicateFinder.canonicalVolume(Double(Int.min)) == String(Int.min))
    }

    @Test func groupsAppliesIgnoreAndOverlapSuppression() {
        // 1,2 are exact (same hash) AND same series/volume → possible group fully ⊆ exact → suppressed
        let books = [
            book(1, hash: "h", series: "S", volume: 1),
            book(2, hash: "h", series: "S", volume: 1),
            book(3, series: "T", volume: 5), book(4, series: "T", volume: 5)
        ]
        let r = DuplicateFinder.groups(books, ignoring: [])
        #expect(r.exact.map(\.key) == ["exact:h"])
        #expect(r.possible.map(\.members.count) == [2])      // only T/5 group; S/1 suppressed (⊆ exact)
        let r2 = DuplicateFinder.groups(books, ignoring: ["exact:h"])
        #expect(r2.exact.isEmpty)                            // ignored
    }
}
