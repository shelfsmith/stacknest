// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("WatchFolderScanner")
struct WatchFolderScannerTests {
    @Test func transientFilesAreExcluded() {
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.part")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.crdownload")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.download")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.tmp")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/.hidden.zip")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/book.zip")) == false)
    }
    @Test func filtersExistingAndBaseline() {
        let all = ["/d/a.zip", "/d/b.zip", "/d/c.part", "/d/d.zip"].map { URL(fileURLWithPath: $0) }
        let result = WatchFolderScanner.importable(topLevel: all,
            existingLibraryPaths: ["/d/a.zip"], baseline: ["/d/b.zip"])
        #expect(result.map { $0.path } == ["/d/d.zip"])
    }
    @Test func stabilityNeedsTwoEqualObservations() {
        let r1 = WatchFolderScanner.decideStable(previous: [:], current: ["/d/a.zip": 100])
        #expect(r1.stable.isEmpty)
        #expect(r1.pending["/d/a.zip"] == 100)
        let r2 = WatchFolderScanner.decideStable(previous: ["/d/a.zip": 100], current: ["/d/a.zip": 100])
        #expect(r2.stable == ["/d/a.zip"])
        let r3 = WatchFolderScanner.decideStable(previous: ["/d/a.zip": 100], current: ["/d/a.zip": 150])
        #expect(r3.stable.isEmpty)
        #expect(r3.pending["/d/a.zip"] == 150)
    }
}
