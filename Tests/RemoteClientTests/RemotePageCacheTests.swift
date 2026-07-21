// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

/// Swift 6 concurrency 下で actor へ渡す @Sendable クロージャから可変状態を触るための参照ボックス。
/// テスト内でのみ使用（単一テストは逐次 await 実行なのでデータ競合は起きない）。
private final class Box<T>: @unchecked Sendable {
    var v: T
    init(_ v: T) { self.v = v }
}

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
        let calls = Box(0)
        let d1 = try await cache.data(for: key(0)) { calls.v += 1; return Data([1,2,3]) }
        #expect(d1 == Data([1,2,3])); #expect(calls.v == 1)
        let d2 = try await cache.data(for: key(0)) { calls.v += 1; return Data([9,9]) }  // hit: fetch 呼ばれない
        #expect(d2 == Data([1,2,3])); #expect(calls.v == 1)
    }

    @Test func evictToLimitRemovesOldest() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 合計300>250 → 最古(page0)退避
        #expect(await cache.totalBytes() <= 250)
        let fetched = Box(false)
        _ = try await cache.data(for: key(0)) { fetched.v = true; return Data(count: 100) }
        #expect(fetched.v)   // page0 は退避済 → 再 fetch
    }

    @Test func protectedNotEvicted() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; clock.v += 10
        await cache.setProtected([key(0)], owner: ObjectIdentifier(cache))   // page0 を保護
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 超過 → 保護外の page1 が先に退避
        let p0 = Box(false), p1 = Box(false)
        _ = try await cache.data(for: key(0)) { p0.v = true; return Data(count: 100) }
        _ = try await cache.data(for: key(1)) { p1.v = true; return Data(count: 100) }
        #expect(!p0.v)   // 保護され残存
        #expect(p1.v)    // 退避され再 fetch
    }

    @Test func evictExpiredByTTL() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 100, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 10) }
        clock.v += 200   // page0 の atime は 1000、now=1200、cutoff=1100 → 期限切れ
        await cache.evictExpired()
        let fetched = Box(false)
        _ = try await cache.data(for: key(0)) { fetched.v = true; return Data(count: 10) }
        #expect(fetched.v)
    }

    @Test func deleteBookRemovesOnlyThatBook() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        _ = try await cache.data(for: key(0, book: 1)) { Data(count: 10) }
        _ = try await cache.data(for: key(0, book: 2)) { Data(count: 10) }
        await cache.deleteBook(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, libraryUUID: "lib", bookID: 1)
        let b1 = Box(false), b2 = Box(false)
        _ = try await cache.data(for: key(0, book: 1)) { b1.v = true; return Data(count: 10) }
        _ = try await cache.data(for: key(0, book: 2)) { b2.v = true; return Data(count: 10) }
        #expect(b1.v); #expect(!b2.v)
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
        let fetched = Box(false)
        _ = try await cache.data(for: key(0)) { fetched.v = true; return Data(count: 10) }
        #expect(fetched.v)   // 欠損行が掃除され miss → 再 fetch
    }

    @Test func protectedUnionAcrossOwners() async throws {
        final class Owner {}
        let o1 = Owner(), o2 = Owner()
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; clock.v += 10
        await cache.setProtected([key(0)], owner: ObjectIdentifier(o1))
        await cache.setProtected([key(1)], owner: ObjectIdentifier(o2))
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 超過 → 保護外(page2以外は全保護)
        let p0 = Box(false), p1 = Box(false)
        _ = try await cache.data(for: key(0)) { p0.v = true; return Data(count: 100) }
        _ = try await cache.data(for: key(1)) { p1.v = true; return Data(count: 100) }
        #expect(!p0.v); #expect(!p1.v)   // 両 owner の保護が union で効く
        // o1 を解除 → page0 は保護外に
        await cache.clearProtected(owner: ObjectIdentifier(o1))
        _ = try await cache.data(for: key(3)) { Data(count: 100) }   // 超過 → 保護外の page0 が退避
        let q0 = Box(false)
        _ = try await cache.data(for: key(0)) { q0.v = true; return Data(count: 100) }
        #expect(q0.v)   // 解除後 page0 は退避され再 fetch
    }

    @Test func cachedPagesReturnsMatchingPageIndices() async throws {
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0)
        let sid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        _ = try await cache.data(for: key(2)) { Data(count: 10) }              // book1 page2 maxw800
        _ = try await cache.data(for: key(5)) { Data(count: 10) }              // book1 page5 maxw800
        _ = try await cache.data(for: key(0, book: 2)) { Data(count: 10) }     // 別 book
        let otherMaxw = RemotePageCache.Key(serverID: sid, libraryUUID: "lib", bookID: 1, kind: .page, page: 9, maxw: 1600)
        _ = try await cache.data(for: otherMaxw) { Data(count: 10) }           // 別 maxw
        let cover = RemotePageCache.Key(serverID: sid, libraryUUID: "lib", bookID: 1, kind: .cover, page: 0, maxw: 300)
        _ = try await cache.data(for: cover) { Data(count: 10) }               // cover
        let pages = await cache.cachedPages(serverID: sid, libraryUUID: "lib", bookID: 1, maxw: 800, version: nil)
        #expect(pages == [2, 5])
        #expect(await cache.cachedPages(serverID: sid, libraryUUID: "lib", bookID: 99, maxw: 800, version: nil).isEmpty)
    }

    // G17 T1: HIT パス高速化（WAL/deferred atime/in-mem blob）の回帰確認。

    @Test func consecutiveHitsDoNotWriteAtimeSynchronously() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 0, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 10) }   // MISS(store): pendingAtime は確定済みでクリア
        #expect(await cache.debugPendingAtimeKeys().isEmpty)
        clock.v += 5
        _ = try await cache.data(for: key(0)) { Issue.record("expected cache hit"); return Data() }   // HIT
        clock.v += 5
        _ = try await cache.data(for: key(0)) { Issue.record("expected cache hit"); return Data() }   // HIT
        // 連続 HIT は pendingAtime に蓄積されるのみ（同期 UPDATE は発生しない）。
        #expect(await cache.debugPendingAtimeKeys() == [key(0).string])
    }

    @Test func evictionRespectsRecencyAfterDeferredAtimeHits() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; clock.v += 10   // page0 atime=1000
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; clock.v += 10   // page1 atime=1010
        // page0 を HIT（最近使った扱いにする）。この時点では pendingAtime に溜まるのみで DB 未反映。
        _ = try await cache.data(for: key(0)) { Issue.record("expected cache hit"); return Data() }
        clock.v += 10
        // page2 追加で容量超過(300>250) → evictToLimit が走る。deferred atime を flush してから
        // ORDER BY atime するはずなので、直近 HIT した page0 ではなく page1 が退避されるべき。
        _ = try await cache.data(for: key(2)) { Data(count: 100) }
        let fetched0 = Box(false), fetched1 = Box(false)
        _ = try await cache.data(for: key(0)) { fetched0.v = true; return Data(count: 100) }
        _ = try await cache.data(for: key(1)) { fetched1.v = true; return Data(count: 100) }
        #expect(!fetched0.v)   // page0 は直前 HIT の deferred atime が反映され残存
        #expect(fetched1.v)    // page1 が真の最古として退避され再フェッチが必要
    }

    @Test func explicitFlushPersistsAtimeToDatabase() async throws {
        let clock = Box<Int64>(1000)
        let cache = RemotePageCache(baseDirectory: tempDir(), limitBytes: 250, maxAgeSeconds: 0, now: { clock.v })
        _ = try await cache.data(for: key(0)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(1)) { Data(count: 100) }; clock.v += 10
        _ = try await cache.data(for: key(0)) { Issue.record("expected cache hit"); return Data() }   // HIT: pending に溜まる
        #expect(await cache.debugPendingAtimeKeys() == [key(0).string])
        await cache.flush()
        #expect(await cache.debugPendingAtimeKeys().isEmpty)   // flush 後は pending が空
        clock.v += 10
        // flush 済みの atime が DB に永続化されていることを、後続の eviction の LRU 順序で確認する。
        _ = try await cache.data(for: key(2)) { Data(count: 100) }   // 容量超過 → evictToLimit
        let fetched0 = Box(false), fetched1 = Box(false)
        _ = try await cache.data(for: key(0)) { fetched0.v = true; return Data(count: 100) }
        _ = try await cache.data(for: key(1)) { fetched1.v = true; return Data(count: 100) }
        #expect(!fetched0.v)   // flush 済みの新しい atime のおかげで page0 は残存
        #expect(fetched1.v)    // page1 が退避される
    }

    @Test func keyVersionChangesStringAndIsBackwardCompatibleWhenNil() {
        let sid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        // version nil はページ用＝現行キー文字列と完全一致（後方互換）
        let pageKey = RemotePageCache.Key(serverID: sid, libraryUUID: "u", bookID: 5, kind: .page, page: 3, maxw: 1600)
        #expect(pageKey.string == "\(sid.uuidString)|u|5|page|3|1600")
        // cover: version 有無/差で string が変わる
        let noVer = RemotePageCache.Key(serverID: sid, libraryUUID: "u", bookID: 5, kind: .cover, page: 0, maxw: 600)
        let v1 = RemotePageCache.Key(serverID: sid, libraryUUID: "u", bookID: 5, kind: .cover, page: 0, maxw: 600, version: "c5-100-2000")
        let v2 = RemotePageCache.Key(serverID: sid, libraryUUID: "u", bookID: 5, kind: .cover, page: 0, maxw: 600, version: "c5-200-2100")
        #expect(noVer.string == "\(sid.uuidString)|u|5|cover|cover|600")   // version nil は現行同一
        #expect(v1.string == "\(sid.uuidString)|u|5|cover|cover|600|vc5-100-2000")
        #expect(v1.string != v2.string)
        #expect(v1 != v2)   // Hashable/Equatable も版で区別
    }
}
