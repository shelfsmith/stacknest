// SPDX-License-Identifier: MIT
import Foundation
import GRDB
import CryptoKit
import os

/// リモートページ/表紙バイトのディスク永続キャッシュ（ファイル blob ＋ SQLite 索引）。
/// LRU（atime 昇順で上限まで退避）＋可視保護（setProtected）＋TTL（evictExpired）。best-effort。
public actor RemotePageCache {
    public static let shared = RemotePageCache()
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemotePageCache")

    public struct Key: Hashable, Sendable {
        public enum Kind: String, Sendable { case page, cover }
        public let serverID: UUID
        public let libraryUUID: String
        public let bookID: Int
        public let kind: Kind
        public let page: Int
        public let maxw: Int?
        /// 表紙の版トークン（cover のみ・thumbnail の mtime+size 由来）。
        /// page は nil ＝キー文字列は現行維持（既存ディスクキャッシュ後方互換）。
        public let version: String?
        public init(serverID: UUID, libraryUUID: String, bookID: Int, kind: Kind, page: Int, maxw: Int?, version: String? = nil) {
            self.serverID = serverID; self.libraryUUID = libraryUUID; self.bookID = bookID
            self.kind = kind; self.page = page; self.maxw = maxw; self.version = version
        }
        public var string: String {
            let where_ = kind == .page ? String(page) : "cover"
            let base = "\(serverID.uuidString)|\(libraryUUID)|\(bookID)|\(kind.rawValue)|\(where_)|\(maxw.map(String.init) ?? "full")"
            if let version { return base + "|v\(version)" }
            return base
        }
        public var book: String { "\(serverID.uuidString)|\(libraryUUID)|\(bookID)" }
    }

    private let baseDir: URL
    private let blobsDir: URL
    private let tmpDir: URL
    private var limitBytes: Int64
    private var maxAgeSeconds: Int64
    private let now: @Sendable () -> Int64
    private var protectedByOwner: [ObjectIdentifier: Set<String>] = [:]
    private let queue: DatabaseQueue
    private let fm = FileManager.default
    // G17 T1: HIT パスの高速化。
    // - pendingAtime: readHit() で atime を同期 UPDATE せず、ここに溜める（key.string -> atime）。
    //   実体化（flush）は evictToLimit/evictExpired の先頭（eviction 判定前）と、公開 flush()
    //   （アプリ終了フックからの best-effort 呼び出し）で行う。eviction は必ず flush 後に
    //   ORDER BY atime するため、direct-evict 経路の LRU 順序は常に最新の pending 分を反映する。
    //   プロセスクラッシュ等で未 flush のまま失われた場合は該当 key の atime が旧値のまま残るのみ
    //   （最悪でも「本来より古く見えて先に退避されうる」程度の劣化。best-effort cache の許容範囲）。
    private var pendingAtime: [String: Int64] = [:]
    // L1: プロセス内メモリ blob キャッシュ（SQLite/ファイル I/O を完全スキップする前段）。
    // key は Key.string。totalCostLimit はバイト数換算の目安（NSCache は保証ではなくヒント）。
    private let blobMemCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    public init(baseDirectory: URL? = nil,
                limitBytes: Int64 = 2 * 1024 * 1024 * 1024,
                maxAgeSeconds: Int64 = 30 * 24 * 3600,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        let base = baseDirectory ?? {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return appSup.appendingPathComponent("StackNest/RemoteCache", isDirectory: true)
        }()
        self.baseDir = base
        self.blobsDir = base.appendingPathComponent("blobs", isDirectory: true)
        self.tmpDir = base.appendingPathComponent("tmp", isDirectory: true)
        self.limitBytes = limitBytes
        self.maxAgeSeconds = maxAgeSeconds
        self.now = now
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // 索引 DB。失敗時はメモリ DB にフォールバック（best-effort・当該セッションは L2 永続化が効かない）。
        // G17 T1: WAL + synchronous=NORMAL で HIT/MISS 双方の SQLite トランザクションを軽量化する
        // （ロールバックジャーナルの毎回 fsync を避ける。クラッシュ時の耐久性は best-effort cache
        //   なので妥協可＝deleteBook 等の破損時は reconcile() が孤立行/孤立 blob を掃除する）。
        let dbURL = base.appendingPathComponent("index.sqlite")
        let q: DatabaseQueue
        if let disk = try? DatabaseQueue(path: dbURL.path, configuration: Self.makeConfiguration()) {
            q = disk
        } else {
            Self.logger.error("disk index open failed at \(dbURL.path, privacy: .public) — falling back to in-memory (L2 persistence disabled this session)")
            q = (try? DatabaseQueue(configuration: Self.makeConfiguration())) ?? { fatalError("RemotePageCache: in-memory DatabaseQueue failed") }()
        }
        self.queue = q
        try? q.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entries(
                  key TEXT PRIMARY KEY, book TEXT NOT NULL, kind TEXT NOT NULL,
                  bytes INTEGER NOT NULL, atime INTEGER NOT NULL, file TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS byAtime ON entries(atime);
                CREATE INDEX IF NOT EXISTS byBook ON entries(book);
                """)
        }
    }

    // MARK: - 公開 API

    public func data(for key: Key, fetch: @Sendable () async throws -> Data) async throws -> Data {
        if let hit = readHit(key) { return hit }
        let data = try await fetch()
        store(key: key, data: data)          // best-effort（失敗しても data を返す）
        evictExpired()
        evictToLimit()
        return data
    }

    public func setProtected(_ keys: Set<Key>, owner: ObjectIdentifier) {
        protectedByOwner[owner] = Set(keys.map { $0.string })
    }
    public func clearProtected(owner: ObjectIdentifier) {
        protectedByOwner.removeValue(forKey: owner)
    }

    public func setLimit(_ bytes: Int64) { limitBytes = bytes; evictToLimit() }
    public func setMaxAge(_ seconds: Int64) { maxAgeSeconds = seconds; evictExpired() }

    public func totalBytes() -> Int64 {
        ((try? queue.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes),0) FROM entries") }) ?? nil) ?? 0
    }

    public func evictToLimit() {
        guard limitBytes > 0 else { return }
        flushPendingAtime()   // ORDER BY atime の前に確定させる（deferred atime を反映した正しい LRU 順）
        var total = totalBytes()
        guard total > limitBytes else { return }
        let protectedUnion = protectedByOwner.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, bytes, file FROM entries ORDER BY atime ASC")
        }) ?? []
        for row in rows {
            if total <= limitBytes { break }
            let k: String = row["key"]; let bytes: Int64 = row["bytes"]; let file: String = row["file"]
            if protectedUnion.contains(k) { continue }
            removeRowAndBlob(key: k, file: file)
            total -= bytes
        }
    }

    public func evictExpired() {
        guard maxAgeSeconds > 0 else { return }
        flushPendingAtime()   // WHERE atime < cutoff の前に確定させる（deferred atime を反映）
        let cutoff = now() - maxAgeSeconds
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, file FROM entries WHERE atime < ?", arguments: [cutoff])
        }) ?? []
        for row in rows { removeRowAndBlob(key: row["key"], file: row["file"]) }
    }

    public func deleteBook(serverID: UUID, libraryUUID: String, bookID: Int) {
        let book = "\(serverID.uuidString)|\(libraryUUID)|\(bookID)"
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, file FROM entries WHERE book = ?", arguments: [book])
        }) ?? []
        for row in rows { removeRowAndBlob(key: row["key"], file: row["file"]) }
    }

    /// その本の L2 キャッシュ済みページ番号集合（指定 maxw のページのみ）。プログレスバー可視化用。
    /// キー形式 `serverID|libraryUUID|bookID|kind|<page>|<maxw>` をパースする。best-effort（失敗は空集合）。
    public func cachedPages(serverID: UUID, libraryUUID: String, bookID: Int, maxw: Int?) -> Set<Int> {
        let book = "\(serverID.uuidString)|\(libraryUUID)|\(bookID)"
        let maxwField = maxw.map(String.init) ?? "full"
        let keys = (try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM entries WHERE book = ? AND kind = 'page'", arguments: [book])
        }) ?? []
        var pages = Set<Int>()
        for k in keys {
            let f = k.split(separator: "|", omittingEmptySubsequences: false)
            // G4d 層2: version 付きキーは末尾に "|v<version>" が付き 7 要素になる（無版は 6 要素）。
            // 版に関わらず「キャッシュ済みか」を数えるだけなので、先頭 6 要素が読めれば十分（>=6）。
            guard f.count >= 6, f[5] == maxwField, let p = Int(f[4]) else { continue }
            pages.insert(p)
        }
        return pages
    }

    /// 表紙のみ無効化（差し替え時。本文ページキャッシュは温存）。
    public func deleteCovers(serverID: UUID, libraryUUID: String, bookID: Int) {
        let book = "\(serverID.uuidString)|\(libraryUUID)|\(bookID)"
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, file FROM entries WHERE book = ? AND kind = 'cover'", arguments: [book])
        }) ?? []
        for row in rows { removeRowAndBlob(key: row["key"], file: row["file"]) }
    }

    public func clearAll() {
        try? queue.write { db in try db.execute(sql: "DELETE FROM entries") }
        try? fm.removeItem(at: blobsDir)
        try? fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        pendingAtime.removeAll()
        blobMemCache.removeAllObjects()
    }

    public func reconcile() {
        // 1) 行はあるが blob 欠損/サイズ不一致 → 行削除
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, bytes, file FROM entries")
        }) ?? []
        var validFiles = Set<String>()
        for row in rows {
            let file: String = row["file"]; let bytes: Int64 = row["bytes"]; let k: String = row["key"]
            let url = blobsDir.appendingPathComponent(file)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            if size == bytes { validFiles.insert(file) } else { removeRowAndBlob(key: k, file: file) }
        }
        // 2) blob はあるが行が無い（孤立ファイル）→ 削除
        if let all = fm.enumerator(at: blobsDir, includingPropertiesForKeys: nil) {
            for case let f as URL in all where !f.hasDirectoryPath {
                let rel = f.path.replacingOccurrences(of: blobsDir.path + "/", with: "")
                if !validFiles.contains(rel) { try? fm.removeItem(at: f) }
            }
        }
        evictExpired()
    }

    /// アプリ終了フック等から呼ぶ best-effort フラッシュ。pendingAtime を DB へ反映する。
    /// 非同期 fire-and-forget（`Task { await RemotePageCache.shared.flush() }`）で呼ばれる場合、
    /// プロセス終了と競合し得るため完了は保証されない（best-effort cache の許容範囲）。
    public func flush() {
        flushPendingAtime()
    }

    /// テスト観測用（internal＝`@testable import` からのみ到達可能。非 public API）。
    /// pendingAtime に溜まっている key を返す（HIT パスが同期 DB write をしていないことの確認用）。
    func debugPendingAtimeKeys() -> Set<String> { Set(pendingAtime.keys) }

    // MARK: - 内部

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    /// pendingAtime の内容を 1 トランザクションで DB へ反映してクリアする。
    /// 呼び出し元: evictToLimit/evictExpired（eviction 判定の直前・必須）／flush()（best-effort）。
    private func flushPendingAtime() {
        guard !pendingAtime.isEmpty else { return }
        let snapshot = pendingAtime
        pendingAtime.removeAll(keepingCapacity: true)
        try? queue.write { db in
            for (key, atime) in snapshot {
                try db.execute(sql: "UPDATE entries SET atime = ? WHERE key = ?", arguments: [atime, key])
            }
        }
    }

    private func fileName(for key: Key) -> String {
        let hash = SHA256.hash(data: Data(key.string.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(hash.prefix(2))/\(hash)"
    }

    private func readHit(_ key: Key) -> Data? {
        // L1: メモリ blob キャッシュにあれば SQLite/ファイル I/O を完全スキップ。
        if let cached = blobMemCache.object(forKey: key.string as NSString) {
            pendingAtime[key.string] = now()
            return cached as Data
        }
        // L2 HIT パス: SELECT + blob 読みのみ（同期 atime UPDATE は行わない＝pendingAtime に蓄積）。
        guard let row = ((try? queue.read({ db in
            try Row.fetchOne(db, sql: "SELECT bytes, file FROM entries WHERE key = ?", arguments: [key.string])
        })) ?? nil) else { return nil }
        let bytes: Int64 = row["bytes"]; let file: String = row["file"]
        let url = blobsDir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), Int64(data.count) == bytes else {
            removeRowAndBlob(key: key.string, file: file)   // 破損 → miss
            return nil
        }
        pendingAtime[key.string] = now()
        blobMemCache.setObject(data as NSData, forKey: key.string as NSString, cost: data.count)
        return data
    }

    private func store(key: Key, data: Data) {
        let file = fileName(for: key)
        let dest = blobsDir.appendingPathComponent(file)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO entries(key, book, kind, bytes, atime, file) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(key) DO UPDATE SET bytes=excluded.bytes, atime=excluded.atime, file=excluded.file
                    """, arguments: [key.string, key.book, key.kind.rawValue, Int64(data.count), now(), file])
            }
            pendingAtime.removeValue(forKey: key.string)   // 新規 write の atime は上で確定済み
            blobMemCache.setObject(data as NSData, forKey: key.string as NSString, cost: data.count)
        } catch {
            try? fm.removeItem(at: tmp)   // best-effort
            // Codex Low1: write 失敗時は当該 key の L1/index/blob を破棄し、次回クリーン再取得へ倒す。
            // （actor 再入＋file 差し替え後に index write 失敗すると、L1 の旧バイトと disk の新バイトが
            //  食い違い、以後 L1 から stale を返してしまうため。同一 key を完全に purge して整合させる。）
            blobMemCache.removeObject(forKey: key.string as NSString)
            pendingAtime.removeValue(forKey: key.string)
            try? queue.write { db in
                try db.execute(sql: "DELETE FROM entries WHERE key = ?", arguments: [key.string])
            }
            try? fm.removeItem(at: dest)
        }
    }

    private func removeRowAndBlob(key: String, file: String) {
        try? queue.write { db in try db.execute(sql: "DELETE FROM entries WHERE key = ?", arguments: [key]) }
        try? fm.removeItem(at: blobsDir.appendingPathComponent(file))
        pendingAtime.removeValue(forKey: key)
        blobMemCache.removeObject(forKey: key as NSString)
    }
}
