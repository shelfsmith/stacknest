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
        public init(serverID: UUID, libraryUUID: String, bookID: Int, kind: Kind, page: Int, maxw: Int?) {
            self.serverID = serverID; self.libraryUUID = libraryUUID; self.bookID = bookID
            self.kind = kind; self.page = page; self.maxw = maxw
        }
        public var string: String {
            let where_ = kind == .page ? String(page) : "cover"
            return "\(serverID.uuidString)|\(libraryUUID)|\(bookID)|\(kind.rawValue)|\(where_)|\(maxw.map(String.init) ?? "full")"
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
        let dbURL = base.appendingPathComponent("index.sqlite")
        let q: DatabaseQueue
        if let disk = try? DatabaseQueue(path: dbURL.path) {
            q = disk
        } else {
            Self.logger.error("disk index open failed at \(dbURL.path, privacy: .public) — falling back to in-memory (L2 persistence disabled this session)")
            q = (try? DatabaseQueue()) ?? { fatalError("RemotePageCache: in-memory DatabaseQueue failed") }()
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

    // MARK: - 内部

    private func fileName(for key: Key) -> String {
        let hash = SHA256.hash(data: Data(key.string.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(hash.prefix(2))/\(hash)"
    }

    private func readHit(_ key: Key) -> Data? {
        guard let row = ((try? queue.read({ db in
            try Row.fetchOne(db, sql: "SELECT bytes, file FROM entries WHERE key = ?", arguments: [key.string])
        })) ?? nil) else { return nil }
        let bytes: Int64 = row["bytes"]; let file: String = row["file"]
        let url = blobsDir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), Int64(data.count) == bytes else {
            removeRowAndBlob(key: key.string, file: file)   // 破損 → miss
            return nil
        }
        try? queue.write { db in
            try db.execute(sql: "UPDATE entries SET atime = ? WHERE key = ?", arguments: [now(), key.string])
        }
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
        } catch {
            try? fm.removeItem(at: tmp)   // best-effort
        }
    }

    private func removeRowAndBlob(key: String, file: String) {
        try? queue.write { db in try db.execute(sql: "DELETE FROM entries WHERE key = ?", arguments: [key]) }
        try? fm.removeItem(at: blobsDir.appendingPathComponent(file))
    }
}
