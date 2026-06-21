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
    case author, rating, genre, unseen, bookType, volume, neta, keywordA, keywordB, keywordC, memo

    /// 明示 order が無いときの自然な既定方向。
    /// テスト系（title/series/author/genre/neta/keywordA/keywordB/keywordC/memo）=asc、
    /// 数値・日付・状態系（dateAdded/lastRead/rating/unseen/bookType/volume）=desc。
    var defaultOrder: SortOrder {
        switch self {
        case .title, .series, .author, .genre, .neta, .keywordA, .keywordB, .keywordC, .memo:
            return .asc
        case .dateAdded, .lastRead, .rating, .unseen, .bookType, .volume:
            return .desc
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
        case .author:
            return books.sorted {
                ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending
            }
        case .rating:
            return books.sorted { $0.rating < $1.rating }
        case .genre:
            return books.sorted {
                ($0.genre ?? "").localizedStandardCompare($1.genre ?? "") == .orderedAscending
            }
        case .unseen:
            return books.sorted { ($0.unseen ? 1 : 0) < ($1.unseen ? 1 : 0) }
        case .bookType:
            return books.sorted { $0.bookType < $1.bookType }
        case .volume:
            return books.sorted { ($0.volume ?? 0) < ($1.volume ?? 0) }
        case .neta:
            return books.sorted {
                ($0.neta ?? "").localizedStandardCompare($1.neta ?? "") == .orderedAscending
            }
        case .keywordA:
            return books.sorted {
                ($0.keywordA ?? "").localizedStandardCompare($1.keywordA ?? "") == .orderedAscending
            }
        case .keywordB:
            return books.sorted {
                ($0.keywordB ?? "").localizedStandardCompare($1.keywordB ?? "") == .orderedAscending
            }
        case .keywordC:
            return books.sorted {
                ($0.keywordC ?? "").localizedStandardCompare($1.keywordC ?? "") == .orderedAscending
            }
        case .memo:
            return books.sorted {
                ($0.memo ?? "").localizedStandardCompare($1.memo ?? "") == .orderedAscending
            }
        }
    }
}

/// books 一覧のクエリ処理（検索は title/series/author の大小文字無視 contains・NFC 正規化済み前提）。
struct BooksQuery {
    let q: String?
    let sort: BookSortKey
    let order: SortOrder
    let page: Int      // 1-based
    let per: Int       // clamp 1...500
    let scope: SidebarScope
    let filter: FilterState
    let browse: [(String, String)]
    /// 応答に含める追加フィールド名（&fields= で要求された列のみ充填する）。
    let extraFields: Set<String>

    init(
        q: String?,
        sort: BookSortKey,
        order: SortOrder,
        page: Int,
        per: Int,
        scope: SidebarScope = .library,
        filter: FilterState = FilterState(),
        browse: [(String, String)] = [],
        extraFields: Set<String> = []
    ) {
        self.q = q; self.sort = sort; self.order = order
        self.page = page; self.per = per
        self.scope = scope; self.filter = filter; self.browse = browse
        self.extraFields = extraFields
    }

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
        // 全ケースを searchBooks(query:sidebarScope:filter:browserConstraints:) に統一。
        // q=nil の空クエリ + filter/browse なし の場合は内部で fetchAllBooks() 高速パスに分岐する。
        let rows = try lib.db.searchBooks(
            query: q ?? "",
            sidebarScope: scope,
            filter: filter,
            browserConstraints: browse.map { (column: $0.0, value: $0.1) }
        )
        let progress = try lib.db.fetchAllViewerStates()
        // hasCover は Thumbnails/ 1 回 listing の安価な近似（全件可）。
        // coverVersion は thumbnail.jpg 個別 stat が必要なため、全件 stat（5,000 回）を避け
        // フィルタ/ソート/スライス後の本（per ≤ 500）に限定して算出する（plan Task 1(b)）。
        let coverIDs = Self.coverBookIDs(bundleURL: lib.bundleURL)
        // 追加フィールドは全件「完全充填」してからソートする（fill→sort）。
        // memo はここでは切詰めず、応答スライス時（keepingExtras）に 200 字へ落とす。
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
                coverVersion: nil,   // スライス後に表紙ありの本のみ埋める
                genre: row.genre, neta: row.neta,
                keywordA: row.keywordA, keywordB: row.keywordB, keywordC: row.keywordC, memo: row.memo,
                coverCropRectJSON: row.coverCropRect.map(BookRow.encodeCoverCropRect)
            )
        }
        items = sort.sortedAscending(items)
        if order == .desc { items.reverse() }
        let total = items.count
        let start = (page - 1) * per
        let slice = start < total ? Array(items[start..<min(start + per, total)]) : []
        // 応答スライスを要求フィールドへマスク（&fields= 外を nil 化・memo 200 字切詰）。
        let masked = slice.map { $0.keepingExtras(extraFields) }
        // スライス分だけ表紙ファイルを stat して coverVersion を付与（引用符は除いた素の文字列）。
        let withVersion = masked.map { item -> BookListItemDTO in
            guard item.hasCover else { return item }
            let url = coverURL(bundleURL: lib.bundleURL, bookID: item.id)
            let version = thumbnailETag(url: url, bookID: item.id)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return item.withCoverVersion(version)
        }
        return BookPageDTO(items: withVersion, total: total, page: page, perPage: per)
    }
}

