// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import OSLog

struct DuplicateScanResult: Sendable {
    var exact: [DuplicateGroup] = []
    var possible: [DuplicateGroup] = []
    var missingCount: Int = 0     // path 無し/読めない
    var hashedCount: Int = 0      // 今回 SHA-256 を計算した件数
    var candidateCount: Int = 0   // 単一ファイルの候補数
}

/// Phase 2.7 A20/B11: 重複検出スキャン。サイズ事前絞り込みで必要分だけ SHA-256 を計算し
/// content_hash をキャッシュ、DuplicateFinder でグループ化する。中断可。
@MainActor
final class DuplicateScanTask {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "DuplicateScan")
    private let database: Database
    private let ignoredKeys: Set<String>
    private(set) var cancelled = false
    private(set) var processed = 0
    private(set) var total = 0

    init(database: Database, ignoredKeys: Set<String>) {
        self.database = database
        self.ignoredKeys = ignoredKeys
    }

    func cancel() { cancelled = true }

    func run(onProgress: @escaping @MainActor (Int, Int) -> Void) async -> DuplicateScanResult {
        var result = DuplicateScanResult()
        let books = (try? database.fetchAllBooks()) ?? []

        // 1) 候補選別 + サイズ収集（通常ファイルのみ。ディレクトリ/欠落は exact 対象外）
        var sizes: [(id: Int, size: Int64)] = []
        var meta: [Int: (url: URL, size: Int64, mtime: Double)] = [:]
        let fm = FileManager.default
        for b in books {
            guard let p = b.path else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { result.missingCount += 1; continue }
            if isDir.boolValue { continue }   // フォルダ型は exact 非対象（possible は metadata で拾う）
            let url = URL(fileURLWithPath: p)
            let attrs = try? fm.attributesOfItem(atPath: p)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            sizes.append((b.id, size))
            meta[b.id] = (url, size, mtime)
        }
        result.candidateCount = sizes.count

        // 2) サイズ事前絞り込み
        let need = DuplicateFinder.idsNeedingHash(sizes: sizes)
        // キャッシュ有効（size&mtime 一致 & hash 済み）は再利用、それ以外を計算対象に
        let bookByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        var toHash: [Int] = []
        for id in need {
            guard let m = meta[id], let b = bookByID[id] else { continue }
            if let h = b.contentHash, !h.isEmpty, b.fileSize == m.size, b.fileMtime == m.mtime { continue }
            toHash.append(id)
        }
        total = toHash.count

        // 3) ハッシュ計算 + 保存
        for id in toHash {
            if cancelled { break }
            defer { processed += 1; onProgress(processed, total) }
            guard let m = meta[id] else { continue }
            do {
                let hash = try await Task.detached { try ContentHasher.sha256(ofFileAt: m.url) }.value
                try database.updateBookContentHash(id: id, hash: hash, size: m.size, mtime: m.mtime)
                result.hashedCount += 1
            } catch {
                Self.logger.warning("hash failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 4) 再取得してグルーピング（無視キー除外・overlap 抑制）
        let fresh = (try? database.fetchAllBooks()) ?? books
        let g = DuplicateFinder.groups(fresh, ignoring: ignoredKeys)
        result.exact = g.exact
        result.possible = g.possible
        return result
    }
}
