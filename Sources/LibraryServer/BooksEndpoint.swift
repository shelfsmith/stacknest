// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import LibraryServerAPI

/// ソート方向（不正値は 400 — 設計ノートのエラー写像）。
enum SortOrder: String {
    case asc, desc
}

/// ソートキー（不正値は 400 — 設計ノートのエラー写像）。
/// `sort` は常に昇順（asc）で並べ、降順は呼び出し側で reverse する（order と直交させる）。
enum BookSortKey: String {
    case title, series, dateAdded, lastRead

    /// 明示 order が無いときの自然な既定方向（title/series=asc、dateAdded/lastRead=desc）。
    var defaultOrder: SortOrder {
        switch self {
        case .title, .series: return .asc
        case .dateAdded, .lastRead: return .desc
        }
    }

    /// キーごとの昇順ソート。降順は run 側で reversed() する。
    func sortedAscending(_ books: [BookListItemDTO]) -> [BookListItemDTO] {
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
            return books.sorted { $0.dateAdded < $1.dateAdded }
        case .lastRead:
            return books.sorted { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }
        }
    }
}

/// books 一覧のクエリ処理（検索は title/series/author の大小文字無視 contains・NFC 正規化済み前提）。
struct BooksQuery {
    let q: String?
    let sort: BookSortKey
    let order: SortOrder
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
        // q 指定時はローカルと同じ FTS5(searchBooks) で絞り込み集合を得る。空時は全件高速パス。
        let rows: [BookRow]
        if let q, !q.isEmpty {
            rows = try lib.db.searchBooks(query: q, sidebarScope: .library)
        } else {
            rows = try lib.db.fetchAllBooks()
        }
        let progress = try lib.db.fetchAllViewerStates()
        // hasCover は Thumbnails/ 1 回 listing の安価な近似（全件可）。
        // coverVersion は thumbnail.jpg 個別 stat が必要なため、全件 stat（5,000 回）を避け
        // フィルタ/ソート/スライス後の本（per ≤ 500）に限定して算出する（plan Task 1(b)）。
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
                hasCover: coverIDs.contains(row.id),
                coverVersion: nil   // スライス後に表紙ありの本のみ埋める
            )
        }
        items = sort.sortedAscending(items)
        if order == .desc { items.reverse() }
        let total = items.count
        let start = (page - 1) * per
        let slice = start < total ? Array(items[start..<min(start + per, total)]) : []
        // スライス分だけ表紙ファイルを stat して coverVersion を付与（引用符は除いた素の文字列）。
        let withVersion = slice.map { item -> BookListItemDTO in
            guard item.hasCover else { return item }
            let url = coverURL(bundleURL: lib.bundleURL, bookID: item.id)
            let version = thumbnailETag(url: url, bookID: item.id)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return item.withCoverVersion(version)
        }
        return BookPageDTO(items: withVersion, total: total, page: page, perPage: per)
    }
}

