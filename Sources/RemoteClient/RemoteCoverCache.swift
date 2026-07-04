// SPDX-License-Identifier: MIT
import Foundation

/// 表紙バイト列のメモリ LRU（NSCache）。可視セルが on-demand で data(for:fetch:) を呼ぶ。
/// 同一キーの同時取得は単純化のため重複許容（最後の結果でキャッシュ更新）。
public actor RemoteCoverCache {
    public struct Key: Hashable, Sendable {
        public let libraryUUID: String
        public let bookID: Int
        public let maxWidth: Int
        public init(libraryUUID: String, bookID: Int, maxWidth: Int) {
            self.libraryUUID = libraryUUID; self.bookID = bookID; self.maxWidth = maxWidth
        }
        var string: String { "\(libraryUUID)#\(bookID)#\(maxWidth)" }
    }

    private let cacheInternal = NSCache<NSString, NSData>()
    private let cache: RemotePageCache?
    private let serverID: UUID?
    private let libraryUUID: String?

    public init(countLimit: Int = 400, cache: RemotePageCache? = .shared, serverID: UUID? = nil, libraryUUID: String? = nil) {
        self.cache = cache
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        cacheInternal.countLimit = countLimit
    }

    /// L1(NSCache) にあれば返し、無ければ L2(RemotePageCache) を挟んで fetch し L1 に格納する。
    public func data(for key: Key, fetch: @Sendable () async throws -> Data) async throws -> Data {
        if let hit = cacheInternal.object(forKey: key.string as NSString) { return hit as Data }
        let data: Data
        if let cache, let serverID, let libraryUUID {
            let l2 = RemotePageCache.Key(serverID: serverID, libraryUUID: libraryUUID, bookID: key.bookID, kind: .cover, page: 0, maxw: key.maxWidth)
            data = try await cache.data(for: l2, fetch: fetch)
        } else {
            data = try await fetch()
        }
        cacheInternal.setObject(data as NSData, forKey: key.string as NSString)
        return data
    }

    /// 4.2c-6b: 表紙差し替え後に該当本のキャッシュを無効化する（再生成 thumbnail を再取得させる）。
    /// 表紙の取得元は cover(maxw=300) と coverImage(maxw=600) の 2 サイズ。
    public func invalidate(libraryUUID: String, bookID: Int) {
        for w in [300, 600] {
            cacheInternal.removeObject(forKey: Key(libraryUUID: libraryUUID, bookID: bookID, maxWidth: w).string as NSString)
        }
    }
}
