// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import AppCore

/// 本ごとの BookContent ハンドルを TTL 付きで保持（アーカイブ再オープン排除・spec §3.3）。
/// key は (libraryUUID, bookID)。アクセスごとに鮮度を更新し、期限切れは次回アクセス時に掃除。
public actor BookContentCache {
    private struct Entry {
        let content: any BookContent
        var lastAccess: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]
    private let ttl: Duration
    private let clock = ContinuousClock()

    public init(ttlSeconds: Int) {
        self.ttl = .seconds(ttlSeconds)
    }

    public func content(for row: BookRow, libraryUUID: String) throws -> any BookContent {
        let key = "\(libraryUUID)/\(row.id)"
        let now = clock.now
        // 期限切れエントリの掃除（呼び出しごとの軽量 sweep）
        entries = entries.filter { now - $0.value.lastAccess < ttl }
        if var entry = entries[key] {
            entry.lastAccess = now
            entries[key] = entry
            return entry.content
        }
        let content = try BookContentFactory.make(for: row)
        entries[key] = Entry(content: content, lastAccess: now)
        return content
    }
}
