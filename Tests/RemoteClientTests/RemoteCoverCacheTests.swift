// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

@Suite("RemoteCoverCache")
struct RemoteCoverCacheTests {
    @Test func cachesAfterFirstFetch() async throws {
        let bytes = Data([1, 2, 3])
        var fetchCount = 0
        let cache = RemoteCoverCache()
        let key = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 300)
        let d1 = try await cache.data(for: key) { fetchCount += 1; return bytes }
        let d2 = try await cache.data(for: key) { fetchCount += 1; return bytes }
        #expect(d1 == bytes)
        #expect(d2 == bytes)
        #expect(fetchCount == 1)   // 2 回目はキャッシュヒット
    }
}
