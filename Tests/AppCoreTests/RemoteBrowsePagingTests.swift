// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("RemoteBrowsePaging — 純ヘルパ＋設定")
struct RemoteBrowsePagingTests {
    @Test func totalPagesCeilAtLeastOne() {
        #expect(remoteTotalPages(total: 0, per: 100) == 1)
        #expect(remoteTotalPages(total: 100, per: 100) == 1)
        #expect(remoteTotalPages(total: 101, per: 100) == 2)
        #expect(remoteTotalPages(total: 250, per: 100) == 3)
        #expect(remoteTotalPages(total: 50, per: 0) == 1)
    }
    @Test func needsNextChunkWhenLoadedBelowTotal() {
        #expect(remoteNeedsNextChunk(loadedCount: 100, total: 250) == true)
        #expect(remoteNeedsNextChunk(loadedCount: 250, total: 250) == false)
        #expect(remoteNeedsNextChunk(loadedCount: 300, total: 250) == false)
    }
    @Test func clampPerToRange() {
        #expect(clampRemotePerPage(10) == 20)
        #expect(clampRemotePerPage(20) == 20)
        #expect(clampRemotePerPage(100) == 100)
        #expect(clampRemotePerPage(500) == 500)
        #expect(clampRemotePerPage(999) == 500)
    }
    @Test func preferencesRoundTrip() {
        let d = UserDefaults(suiteName: "test.rbp.\(UUID().uuidString)")!
        let prefs = RemoteBrowsePreferences(defaults: d)
        #expect(prefs.scrollMode == .paged)
        #expect(prefs.perPageSize == 100)
        prefs.scrollMode = .infinite
        prefs.perPageSize = 999
        let reread = RemoteBrowsePreferences(defaults: d)
        #expect(reread.scrollMode == .infinite)
        #expect(reread.perPageSize == 500)
    }
}
