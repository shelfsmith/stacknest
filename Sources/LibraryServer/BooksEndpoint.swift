// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// books 一覧 1 件分の DTO（spec §3.3）。日付はサーバ共通エンコーダで ISO8601。
public struct BookListItemDTO: Codable, Sendable {
    public let id: Int
    public let title: String
    public let author: String?
    public let series: String?
    public let volume: Double?
    public let rating: Int
    public let unseen: Bool
    public let bookType: Int
    public let pages: Int?
    public let lastPage: Int?
    public let lastReadAt: Date?
    public let dateAdded: Date
    public let hasCover: Bool
}

/// books 一覧のページングレスポンス（spec §3.3）。
public struct BookPageDTO: Codable, Sendable {
    public let items: [BookListItemDTO]
    public let total: Int
    public let page: Int
    public let perPage: Int
}

/// ソートキー（不正値は 400 — 設計ノートのエラー写像）。
enum BookSortKey: String {
    case title, series, dateAdded, lastRead

    func sort(_ books: [BookListItemDTO]) -> [BookListItemDTO] {
        switch self {
        case .title:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .series:
            return books.sorted {
                let s0 = $0.series ?? "", s1 = $1.series ?? ""
                if s0 != s1 { return s0.localizedStandardCompare(s1) == .orderedAscending }
                return ($0.volume ?? 0) < ($1.volume ?? 0)
            }
        case .dateAdded:
            return books.sorted { $0.dateAdded > $1.dateAdded }
        case .lastRead:
            return books.sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        }
    }
}

/// books 一覧のクエリ処理（検索は title/series/author の大小文字無視 contains・NFC 正規化済み前提）。
struct BooksQuery {
    let q: String?
    let sort: BookSortKey
    let page: Int      // 1-based
    let per: Int       // clamp 1...200

    /// 表紙を持つ本の id 集合。
    /// 実規約では表紙は `Thumbnails/<bookID>/thumbnail.jpg`（ファイル名固定）で、
    /// `coverImageName` は手動表紙のアーカイブ内エントリ名 — ディスクファイル名ではない
    /// （自動表紙の本は coverImageName == nil のまま thumbnail.jpg を持つ）。
    /// 冊数分の stat（5,000 冊で 5,000 syscall）を避けるため、Thumbnails/ 直下を
    /// 1 回 listing してサブディレクトリ名（= bookID）の集合を作り照合する。
    /// サブディレクトリは表紙書き込み時（CoverRefresher 等）に作られるため
    /// 「ディレクトリ存在 ≒ 表紙存在」を実用十分な近似として扱う。
    static func coverBookIDs(bundleURL: URL) -> Set<Int> {
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: thumbnailsDir.path) else { return [] }
        return Set(names.compactMap(Int.init))
    }

    func run(on lib: ServedLibrary) throws -> BookPageDTO {
        let rows = try lib.db.fetchAllBooks()
        let progress = try lib.db.fetchAllViewerStates()
        let coverIDs = Self.coverBookIDs(bundleURL: lib.bundleURL)
        var items = rows.map { row in
            BookListItemDTO(
                id: row.id, title: row.title, author: row.author,
                series: row.series, volume: row.volume,
                rating: row.rating, unseen: row.unseen, bookType: row.bookType,
                pages: row.pages,
                lastPage: progress[row.id]?.lastPage,
                lastReadAt: progress[row.id]?.updatedAt,
                dateAdded: row.dateAdded,
                hasCover: coverIDs.contains(row.id)
            )
        }
        if let q, !q.isEmpty {
            let needle = q.precomposedStringWithCanonicalMapping.lowercased()
            items = items.filter {
                $0.title.lowercased().contains(needle)
                    || ($0.series?.lowercased().contains(needle) ?? false)
                    || ($0.author?.lowercased().contains(needle) ?? false)
            }
        }
        items = sort.sort(items)
        let total = items.count
        let start = (page - 1) * per
        let slice = start < total ? Array(items[start..<min(start + per, total)]) : []
        return BookPageDTO(items: slice, total: total, page: page, perPage: per)
    }
}
