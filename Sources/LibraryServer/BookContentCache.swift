// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import AppCore

/// 本ごとの BookContent ハンドルを TTL 付きで保持（アーカイブ再オープン排除・spec §3.3）。
/// key は (libraryUUID, bookID)。アクセスごとに鮮度を更新し、期限切れは次回アクセス時に掃除。
public actor BookContentCache {
    /// row の content 基準（path/mtime/size）。bookETag（ContentEndpoints.swift）と同じ
    /// 3 信号源を使い、relink 後の再構築判定と ETag の変化が食い違わないようにする（G4d 層0）。
    /// mtime/size は effectiveFileStat 経由（＝フォルダブックは nil のとき request 時 stat で埋める）。
    /// これを bookETag と共有しないと、ETag だけが動いてサーバ自身が持つ FolderBookContent の
    /// キャッシュは古いままという食い違いが起きる（最終レビュー Finding 1）。
    private struct Basis: Equatable {
        let path: String?
        let mtime: Double?
        let size: Int64?
    }

    private struct Entry {
        let content: any BookContent
        var lastAccess: ContinuousClock.Instant
        let basis: Basis
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
        let (mtime, size) = effectiveFileStat(for: row)
        let basis = Basis(path: row.path, mtime: mtime, size: size)
        if var entry = entries[key], entry.basis == basis {
            entry.lastAccess = now
            entries[key] = entry
            return entry.content
        }
        // 未キャッシュ、または row の content 基準（path/mtime/size）が変化した＝再構築。
        // 旧 Entry の強参照はここで落ち、ArchiveBookContent→SequentialArchiveExtractor の deinit が
        // 走って temp が即掃除される（リモート temp TTL follow-up を相乗りでカバー）。
        let content = try BookContentFactory.make(for: row)
        entries[key] = Entry(content: content, lastAccess: now, basis: basis)
        return content
    }
}
