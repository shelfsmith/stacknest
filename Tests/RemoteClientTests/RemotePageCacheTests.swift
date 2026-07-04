// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

@Suite("RemotePageCache")
struct RemotePageCacheTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rpc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func key(_ page: Int, book: Int = 1) -> RemotePageCache.Key {
        RemotePageCache.Key(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                            libraryUUID: "lib", bookID: book, kind: .page, page: page, maxw: 800)
    }

    @Test func putGetRoundTrip() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        var calls = 0
        let d1 = try await cache.data(for: key(0)) { calls += 1; return Data([1,2,3]) }
        #expect(d1 == Data([1,2,3])); #expect(calls == 1)
        let d2 = try await cache.data(for: key(0)) { calls += 1; return Data([9,9]) }  // hit: fetch 呼ばれない
        #expect(d2 == Data([1,2,3])); #expect(calls == 1)
    }

    @Test func evictToLimitRemovesOldest() async throws {
        var now: Int64 = 1000
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { now })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; now += 10
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; now += 10
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 合計300>250 → 最古(page0)退避
        #expect(await cache.totalBytes() <= 250)
        var fetched = false
        _ = try await cache.data(for: key(0)) { fetched = true; return Data(count: 100) }
        #expect(fetched)   // page0 は退避済 → 再 fetch
    }

    @Test func protectedNotEvicted() async throws {
        var now: Int64 = 1000
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { now })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; now += 10
        await cache.setProtected([key(0)])   // page0 を保護
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; now += 10
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 超過 → 保護外の page1 が先に退避
        var p0 = false, p1 = false
        _ = try await cache.data(for: key(0)) { p0 = true; return Data(count: 100) }
        _ = try await cache.data(for: key(1)) { p1 = true; return Data(count: 100) }
        #expect(!p0)   // 保護され残存
        #expect(p1)    // 退避され再 fetch
    }

    @Test func evictExpiredByTTL() async throws {
        var now: Int64 = 1000
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 100, now: { now })
        _ = try await cache.data(for: key(0)) { Data(count: 10) }
        now += 200   // page0 の atime は 1000、now=1200、cutoff=1100 → 期限切れ
        await cache.evictExpired()
        var fetched = false
        _ = try await cache.data(for: key(0)) { fetched = true; return Data(count: 10) }
        #expect(fetched)
    }

    @Test func deleteBookRemovesOnlyThatBook() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        _ = try await cache.data(for: key(0, book: 1)) { Data(count: 10) }
        _ = try await cache.data(for: key(0, book: 2)) { Data(count: 10) }
        await cache.deleteBook(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, libraryUUID: "lib", bookID: 1)
        var b1 = false, b2 = false
        _ = try await cache.data(for: key(0, book: 1)) { b1 = true; return Data(count: 10) }
        _ = try await cache.data(for: key(0, book: 2)) { b2 = true; return Data(count: 10) }
        #expect(b1); #expect(!b2)
    }

    @Test func unlimitedDoesNotEvict() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        for p in 0..<20 { _ = try await cache.data(for: key(p)) { Data(count: 1000) } }
        #expect(await cache.totalBytes() == 20_000)
    }

    @Test func reconcileRemovesOrphanRowWhenBlobMissing() async throws {
        let dir = tempDir()
        let cache = RemotePageCache(baseDirectory: dir, limitBytes: 0, maxAgeSeconds: 0)
        _ = try await cache.data(for: key(0)) { Data(count: 10) }
        // blob ファイルを外部から削除して不整合を作る
        let blobs = dir.appendingPathComponent("blobs")
        for f in (try? FileManager.default.subpathsOfDirectory(atPath: blobs.path)) ?? [] where !f.isEmpty {
            let full = blobs.appendingPathComponent(f)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue {
                try? FileManager.default.removeItem(at: full)
            }
        }
        await cache.reconcile()
        var fetched = false
        _ = try await cache.data(for: key(0)) { fetched = true; return Data(count: 10) }
        #expect(fetched)   // 欠損行が掃除され miss → 再 fetch
    }
}
