// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

@Suite("RemoteCoverCache")
struct RemoteCoverCacheTests {
    /// fetch クロージャは @Sendable なので captured var を直接 mutate できない。
    /// 呼び出し回数の計測は actor 経由で行う。
    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test func cachesAfterFirstFetch() async throws {
        let bytes = Data([1, 2, 3])
        let counter = Counter()
        let cache = RemoteCoverCache()
        let key = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 300)
        let d1 = try await cache.data(for: key) { await counter.bump(); return bytes }
        let d2 = try await cache.data(for: key) { await counter.bump(); return bytes }
        #expect(d1 == bytes)
        #expect(d2 == bytes)
        #expect(await counter.count == 1)   // 2 回目はキャッシュヒット
    }
}
