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

    @Test func differentVersionMissesCacheAndRefetches() async throws {
        let counter = Counter()
        let cache = RemoteCoverCache()   // cache: .shared だが version 差で L1 キーが変わる
        let k1 = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 600, version: "v1")
        let k2 = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 600, version: "v2")
        _ = try await cache.data(for: k1) { await counter.bump(); return Data([1]) }
        _ = try await cache.data(for: k1) { await counter.bump(); return Data([1]) }   // 同版=ヒット
        _ = try await cache.data(for: k2) { await counter.bump(); return Data([2]) }   // 別版=ミス→再取得
        #expect(await counter.count == 2)
    }

    @Test func keyStringIncludesVersion() {
        let noVer = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 600)
        let v1 = RemoteCoverCache.Key(libraryUUID: "u", bookID: 5, maxWidth: 600, version: "v1")
        #expect(noVer.string == "u#5#600")            // version nil は現行同一
        #expect(v1.string == "u#5#600#vv1")
        #expect(noVer.string != v1.string)
    }
}
