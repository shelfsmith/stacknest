// SPDX-License-Identifier: MIT
import Foundation

// ─────────────────────────────────────────────────────────────
// 共有 wire 型（Foundation のみ依存・Hummingbird/LibraryStore/AppCore 不使用）
// サーバ側（LibraryServer）とクライアント側（将来の App）が共通でこのモジュールを import する。
// ─────────────────────────────────────────────────────────────

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
    /// 表紙差し替えを Web の `?v=` で追跡するためのバージョン文字列（thumbnail.jpg の mtime+size 由来）。
    /// 表紙なしの本は nil。stat コスト抑制のためページスライス後の本のみ算出する（run 参照）。
    public let coverVersion: String?

    public init(
        id: Int,
        title: String,
        author: String?,
        series: String?,
        volume: Double?,
        rating: Int,
        unseen: Bool,
        bookType: Int,
        pages: Int?,
        lastPage: Int?,
        lastReadAt: Date?,
        dateAdded: Date,
        hasCover: Bool,
        coverVersion: String?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.series = series
        self.volume = volume
        self.rating = rating
        self.unseen = unseen
        self.bookType = bookType
        self.pages = pages
        self.lastPage = lastPage
        self.lastReadAt = lastReadAt
        self.dateAdded = dateAdded
        self.hasCover = hasCover
        self.coverVersion = coverVersion
    }
}

extension BookListItemDTO {
    /// coverVersion だけ差し替えたコピーを返す（全 let のため再構築）。
    public func withCoverVersion(_ version: String?) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author,
            series: series, volume: volume,
            rating: rating, unseen: unseen, bookType: bookType,
            pages: pages, lastPage: lastPage, lastReadAt: lastReadAt,
            dateAdded: dateAdded, hasCover: hasCover, coverVersion: version
        )
    }

    /// lastPage を差し替えた複製（リモート閲覧の進捗をメモリ上の一覧へ反映し、
    /// 一覧を再取得しなくても再オープン時に続きから開くために使う）。
    public func withLastPage(_ page: Int?) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author,
            series: series, volume: volume,
            rating: rating, unseen: unseen, bookType: bookType,
            pages: pages, lastPage: page, lastReadAt: lastReadAt,
            dateAdded: dateAdded, hasCover: hasCover, coverVersion: coverVersion
        )
    }
}

/// books 一覧のページングレスポンス（spec §3.3）。
public struct BookPageDTO: Codable, Sendable {
    public let items: [BookListItemDTO]
    public let total: Int
    public let page: Int
    public let perPage: Int

    public init(items: [BookListItemDTO], total: Int, page: Int, perPage: Int) {
        self.items = items
        self.total = total
        self.page = page
        self.perPage = perPage
    }
}

/// /libraries の一覧 1 件分（spec §3.3）。
public struct LibraryDTO: Codable, Sendable {
    public let id: String
    public let name: String
    public let locked: Bool
    public let bookCount: Int

    public init(id: String, name: String, locked: Bool, bookCount: Int) {
        self.id = id
        self.name = name
        self.locked = locked
        self.bookCount = bookCount
    }
}

/// サーバの capability（spec §3.3 /server/info）。Docker 版は fileOps=false 等で差別化。
public struct ServerCapabilities: Codable, Sendable {
    public var version: String
    public var fileOps: Bool
    public var transcode: Bool
    public var formats: [String]

    public init(version: String, fileOps: Bool, transcode: Bool, formats: [String]) {
        self.version = version
        self.fileOps = fileOps
        self.transcode = transcode
        self.formats = formats
    }

    public static let inApp = ServerCapabilities(
        version: "1", fileOps: true, transcode: false,
        formats: ["zip", "rar", "7z", "folder", "image", "pdf"]
    )
}

/// manifest レスポンス（spec §3.3）。
/// direction は常に "rtl" か "ltr" の具体値を返す（null は返さない）。
public struct ManifestDTO: Codable, Sendable {
    public let pageCount: Int
    public let direction: String     // "rtl" | "ltr"
    public let format: String        // archive / image / folder / video / text
    public let etag: String

    public init(pageCount: Int, direction: String, format: String, etag: String) {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
    }
}

/// unlock 成功レスポンス（短命ライブラリトークン）。
public struct UnlockReply: Codable, Sendable {
    public let libraryToken: String

    public init(libraryToken: String) {
        self.libraryToken = libraryToken
    }
}

/// 棚（ユーザー定義棚 / スマート棚）の一覧 DTO（spec §3.3 /shelves）。
public struct ShelfDTO: Codable, Sendable {
    public let id: Int64
    public let title: String
    public let kind: String
    public let isSmart: Bool
    public init(id: Int64, title: String, kind: String, isSmart: Bool) {
        self.id = id; self.title = title; self.kind = kind; self.isSmart = isSmart
    }
}

/// ブラウズ絞り込み条件 1 件（列名 + 値ペア）。
public struct BrowseConstraint: Codable, Sendable {
    public let column: String
    public let value: String
    public init(column: String, value: String) { self.column = column; self.value = value }
}

/// 書籍詳細 DTO（spec §3.3 /books/:id）。
public struct BookDetailDTO: Codable, Sendable {
    public let id: Int
    public let title: String
    public let author: String?
    public let genre: String?
    public let path: String?
    public let dateAdded: Date
    public let playDate: Date?
    public let bookType: Int
    public let fileType: Int
    public let pages: Int?
    public let rating: Int
    public let unseen: Bool
    public let keywordA: String?
    public let keywordB: String?
    public let keywordC: String?
    public let neta: String?
    public let memo: String?
    public let series: String?
    public let volume: Double?
    public let coverImageName: String?
    public let coverCropRectJSON: String?
    public let pageDirection: String?
    public init(id: Int, title: String, author: String?, genre: String?, path: String?,
                dateAdded: Date, playDate: Date?, bookType: Int, fileType: Int, pages: Int?,
                rating: Int, unseen: Bool, keywordA: String?, keywordB: String?, keywordC: String?,
                neta: String?, memo: String?, series: String?, volume: Double?,
                coverImageName: String?, coverCropRectJSON: String?, pageDirection: String?) {
        self.id = id; self.title = title; self.author = author; self.genre = genre; self.path = path
        self.dateAdded = dateAdded; self.playDate = playDate; self.bookType = bookType
        self.fileType = fileType; self.pages = pages; self.rating = rating; self.unseen = unseen
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.neta = neta; self.memo = memo; self.series = series; self.volume = volume
        self.coverImageName = coverImageName; self.coverCropRectJSON = coverCropRectJSON
        self.pageDirection = pageDirection
    }
}
