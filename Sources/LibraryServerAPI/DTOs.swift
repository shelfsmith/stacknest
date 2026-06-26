// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

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
    /// 4.2c-6b: 表紙クロップ矩形 JSON（リモートグリッド/リストのクロップ適用用）。クロップ無しは nil。
    public let coverCropRectJSON: String?
    // ── 動的フィールド（&fields= で要求された時のみ充填・既定 nil） ──
    public let genre: String?
    public let neta: String?
    public let keywordA: String?
    public let keywordB: String?
    public let keywordC: String?
    public let memo: String?

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
        coverVersion: String?,
        genre: String? = nil, neta: String? = nil,
        keywordA: String? = nil, keywordB: String? = nil, keywordC: String? = nil, memo: String? = nil,
        coverCropRectJSON: String? = nil
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
        self.genre = genre; self.neta = neta
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC; self.memo = memo
        self.coverCropRectJSON = coverCropRectJSON
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
            dateAdded: dateAdded, hasCover: hasCover, coverVersion: version,
            genre: genre, neta: neta, keywordA: keywordA, keywordB: keywordB, keywordC: keywordC, memo: memo,
            coverCropRectJSON: coverCropRectJSON
        )
    }

    /// 応答スライス用。fields に含まれない追加フィールドを nil に落とす。memo は 200 字に切詰。
    public func keepingExtras(_ fields: Set<String>) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author, series: series, volume: volume,
            rating: rating, unseen: unseen, bookType: bookType, pages: pages,
            lastPage: lastPage, lastReadAt: lastReadAt, dateAdded: dateAdded,
            hasCover: hasCover, coverVersion: coverVersion,
            genre: fields.contains("genre") ? genre : nil,
            neta: fields.contains("neta") ? neta : nil,
            keywordA: fields.contains("keywordA") ? keywordA : nil,
            keywordB: fields.contains("keywordB") ? keywordB : nil,
            keywordC: fields.contains("keywordC") ? keywordC : nil,
            memo: fields.contains("memo") ? memo.map { String($0.prefix(200)) } : nil,
            coverCropRectJSON: coverCropRectJSON)
    }

    /// lastPage を差し替えた複製（リモート閲覧の進捗をメモリ上の一覧へ反映し、
    /// 一覧を再取得しなくても再オープン時に続きから開くために使う）。
    public func withLastPage(_ page: Int?) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author,
            series: series, volume: volume,
            rating: rating, unseen: unseen, bookType: bookType,
            pages: pages, lastPage: page, lastReadAt: lastReadAt,
            dateAdded: dateAdded, hasCover: hasCover, coverVersion: coverVersion,
            genre: genre, neta: neta, keywordA: keywordA, keywordB: keywordB, keywordC: keywordC, memo: memo,
            coverCropRectJSON: coverCropRectJSON
        )
    }

    /// unseen フラグだけ差し替えた複製（リモート閲覧で未読マーカーを楽観的に消すために使う）。
    public func withUnseen(_ v: Bool) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author, series: series, volume: volume,
            rating: rating, unseen: v, bookType: bookType, pages: pages,
            lastPage: lastPage, lastReadAt: lastReadAt, dateAdded: dateAdded,
            hasCover: hasCover, coverVersion: coverVersion,
            genre: genre, neta: neta, keywordA: keywordA, keywordB: keywordB, keywordC: keywordC, memo: memo,
            coverCropRectJSON: coverCropRectJSON)
    }

    /// lastReadAt だけ差し替えた複製（リモート閲覧で最終閲覧日時を楽観的に更新するために使う）。
    public func withLastReadAt(_ date: Date?) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: title, author: author, series: series, volume: volume,
            rating: rating, unseen: unseen, bookType: bookType, pages: pages,
            lastPage: lastPage, lastReadAt: date, dateAdded: dateAdded,
            hasCover: hasCover, coverVersion: coverVersion,
            genre: genre, neta: neta, keywordA: keywordA, keywordB: keywordB, keywordC: keywordC, memo: memo,
            coverCropRectJSON: coverCropRectJSON)
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

/// 提示されたトークンに対応するロール（read = R / write = RW）。
public enum TokenRole: String, Codable, Sendable { case read, write }

/// GET /me の応答。提示トークンのロールを返す。
public struct MeReply: Codable, Sendable {
    public let role: TokenRole
    public init(role: TokenRole) { self.role = role }
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

/// 隣接巻（次/前）応答。該当なしは book == nil。
public struct AdjacentVolumeReply: Codable, Sendable {
    public let book: BookListItemDTO?
    public init(book: BookListItemDTO?) { self.book = book }
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
    /// 閲覧進捗の最終ページ（viewer state 由来・⌘⇧O resume で続きから開くために使う）。未読は nil。
    public let lastPage: Int?
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
    /// 4.2c-6b: ファイル拡張子（"zip"/"rar"/""=フォルダ/nil=不明）。path は秘匿で返さないため、
    /// リモート詳細ペインの「ファイル形式」表示用に拡張子だけを別途返す。
    public let fileExtension: String?
    public init(id: Int, title: String, author: String?, genre: String?, path: String?,
                dateAdded: Date, playDate: Date?, bookType: Int, fileType: Int, pages: Int?,
                lastPage: Int? = nil,
                rating: Int, unseen: Bool, keywordA: String?, keywordB: String?, keywordC: String?,
                neta: String?, memo: String?, series: String?, volume: Double?,
                coverImageName: String?, coverCropRectJSON: String?, pageDirection: String?,
                fileExtension: String? = nil) {
        self.id = id; self.title = title; self.author = author; self.genre = genre; self.path = path
        self.dateAdded = dateAdded; self.playDate = playDate; self.bookType = bookType
        self.fileType = fileType; self.pages = pages; self.lastPage = lastPage
        self.rating = rating; self.unseen = unseen
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.neta = neta; self.memo = memo; self.series = series; self.volume = volume
        self.coverImageName = coverImageName; self.coverCropRectJSON = coverCropRectJSON
        self.pageDirection = pageDirection
        self.fileExtension = fileExtension
    }
}

/// PATCH /libraries/:lib/books/:id のリクエスト DTO（メタデータのみ・表紙フィールドなし）。
/// nil フィールドは「変更しない」を意味し、clear* フラグは nil 化（SQL NULL 化）を要求する。
public struct BookPatchDTO: Codable, Sendable {
    public var title: String?
    public var author: String?
    public var genre: String?
    public var neta: String?
    public var memo: String?
    public var keywordA: String?
    public var keywordB: String?
    public var keywordC: String?
    public var rating: Int?
    public var unseen: Bool?
    public var series: String?
    public var volume: Double?
    public var bookType: Int?
    /// ページ方向の上書き（"ltr"/"rtl"/nil=変更しない）。clearPageDirection=true で NULL 化。
    public var pageDirection: String?
    public var clearSeries: Bool
    public var clearVolume: Bool
    public var clearPageDirection: Bool

    public init(
        title: String? = nil, author: String? = nil, genre: String? = nil,
        neta: String? = nil, memo: String? = nil,
        keywordA: String? = nil, keywordB: String? = nil, keywordC: String? = nil,
        rating: Int? = nil, unseen: Bool? = nil,
        series: String? = nil, volume: Double? = nil,
        bookType: Int? = nil, pageDirection: String? = nil,
        clearSeries: Bool = false, clearVolume: Bool = false, clearPageDirection: Bool = false
    ) {
        self.title = title; self.author = author; self.genre = genre; self.neta = neta
        self.memo = memo; self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.rating = rating; self.unseen = unseen; self.series = series; self.volume = volume
        self.bookType = bookType; self.pageDirection = pageDirection
        self.clearSeries = clearSeries; self.clearVolume = clearVolume
        self.clearPageDirection = clearPageDirection
    }
}

// MARK: - 4.2c-6a: スタンプ定義同期＋一括スタンプ適用

/// スタンプ定義マップ（dbColumn → 値配列）の搬送 DTO。
public struct StampDefinitionsDTO: Codable, Sendable {
    public var definitions: [String: [String]]
    public init(definitions: [String: [String]]) { self.definitions = definitions }
}

/// 一括スタンプ適用リクエスト。value（apply=append）/ clear のいずれか。
public struct StampApplyRequest: Codable, Sendable {
    public var field: String
    public var value: String?
    public var clear: Bool?
    public var bookIDs: [Int]
    public init(field: String, value: String? = nil, clear: Bool? = nil, bookIDs: [Int]) {
        self.field = field; self.value = value; self.clear = clear; self.bookIDs = bookIDs
    }
}

/// 一括スタンプ適用レスポンス。
public struct StampApplyReply: Codable, Sendable {
    public var updated: Int
    public init(updated: Int) { self.updated = updated }
}

// MARK: - 4.2c-6b: リモート表紙/クロップ編集

/// 表紙候補（アーカイブのページ名一覧）＋現在の coverImageName。
public struct CoverCandidatesDTO: Codable, Sendable {
    public var entries: [String]
    public var current: String?
    public init(entries: [String], current: String?) { self.entries = entries; self.current = current }
}

/// 表紙更新リクエスト。setCoverImageName=true で coverImageName を更新(nil=自動先頭)＋thumbnail 再生成。
/// setCoverCropRect=true で coverCropRect を更新(nil=クロップ解除)。
public struct CoverUpdateRequest: Codable, Sendable {
    public var coverImageName: String?
    public var setCoverImageName: Bool
    public var coverCropRect: String?
    public var setCoverCropRect: Bool
    public init(coverImageName: String? = nil, setCoverImageName: Bool = false,
                coverCropRect: String? = nil, setCoverCropRect: Bool = false) {
        self.coverImageName = coverImageName; self.setCoverImageName = setCoverImageName
        self.coverCropRect = coverCropRect; self.setCoverCropRect = setCoverCropRect
    }
}

// MARK: - 4.2c-8: リモート ラベルカスタマイズ同期＋編集

/// ライブラリのラベルカスタマイズ（GET 応答・PUT リクエスト共用）。
/// customFieldLabels: key=dbColumn(genre/neta/keyword_a/keyword_b/keyword_c)。
/// customBookTypeLabels: key="0".."5"。空文字値は含めない（サーバ側で除外）。
public struct LabelSettingsDTO: Codable, Sendable {
    public var customFieldLabels: [String: String]
    public var customBookTypeLabels: [String: String]
    public init(customFieldLabels: [String: String], customBookTypeLabels: [String: String]) {
        self.customFieldLabels = customFieldLabels
        self.customBookTypeLabels = customBookTypeLabels
    }
}

// MARK: - 4.2d-2: ヘッドレス write API — add/delete DTO

/// POST /libraries/:lib/books のリクエスト。サーバローカルの絶対パスを追加する。
public struct AddBooksRequestDTO: Codable, Sendable {
    public var paths: [String]
    public var presetID: String?
    public init(paths: [String], presetID: String? = nil) {
        self.paths = paths
        self.presetID = presetID
    }
}

/// POST /libraries/:lib/books のレスポンス。BookImporter.ImportResult の DTO 表現。
public struct AddBooksReplyDTO: Codable, Sendable {
    public var addedIDs: [Int]
    public var alreadyPresent: [String]
    public var failed: [String]
    public init(addedIDs: [Int], alreadyPresent: [String], failed: [String]) {
        self.addedIDs = addedIDs
        self.alreadyPresent = alreadyPresent
        self.failed = failed
    }
}

// MARK: - A1: 棚管理リクエスト DTO

/// 棚の新規作成リクエスト。isSmart=true のとき conditions 必須。
public struct ShelfCreateRequest: Codable, Sendable {
    public var title: String
    public var isSmart: Bool
    public var conditions: SmartShelfConditions?
    public init(title: String, isSmart: Bool, conditions: SmartShelfConditions? = nil) {
        self.title = title; self.isSmart = isSmart; self.conditions = conditions
    }
}

/// 棚の更新リクエスト。title=改名（nil で変更なし）、conditions=スマート棚条件更新（手動棚指定は 409）。
public struct ShelfUpdateRequest: Codable, Sendable {
    public var title: String?
    public var conditions: SmartShelfConditions?
    public init(title: String? = nil, conditions: SmartShelfConditions? = nil) {
        self.title = title; self.conditions = conditions
    }
}

/// 手動棚の所属追加/除去リクエスト。
public struct ShelfBooksRequest: Codable, Sendable {
    public var bookIDs: [Int]
    public init(bookIDs: [Int]) { self.bookIDs = bookIDs }
}

// MARK: - A2: ライブラリ管理 DTO ミラー

/// 監視フォルダ 1 件の DTO（per-library）。
public struct WatchedFolderDTO: Codable, Sendable {
    public var id: String
    public var path: String
    public var enabled: Bool
    public var presetID: String?
    public var baseline: [String]
    public init(id: String, path: String, enabled: Bool, presetID: String? = nil, baseline: [String] = []) {
        self.id = id; self.path = path; self.enabled = enabled; self.presetID = presetID; self.baseline = baseline
    }
}

/// 監視フォルダ設定全体の DTO（enabled フラグ＋フォルダ一覧）。
public struct WatchConfigDTO: Codable, Sendable {
    public var enabled: Bool
    public var folders: [WatchedFolderDTO]
    public init(enabled: Bool, folders: [WatchedFolderDTO]) {
        self.enabled = enabled; self.folders = folders
    }
}

/// ライブラリロック設定リクエスト（パスワード設定）。
public struct LockRequest: Codable, Sendable {
    public var password: String
    public init(password: String) { self.password = password }
}

/// ライブラリ取り込み設定 DTO（per-library override 用。nil = グローバル既定に委譲）。
public struct ImportConfigDTO: Codable, Sendable {
    public var autoClassifyEnabled: Bool?
    public var thickBookThreshold: Int?
    public init(autoClassifyEnabled: Bool? = nil, thickBookThreshold: Int? = nil) {
        self.autoClassifyEnabled = autoClassifyEnabled; self.thickBookThreshold = thickBookThreshold
    }
}

/// グローバル取り込み設定 DTO（nil なし・サーバ canonical）。
public struct GlobalImportConfigDTO: Codable, Sendable {
    public var autoClassifyEnabled: Bool
    public var thickBookThreshold: Int
    public init(autoClassifyEnabled: Bool, thickBookThreshold: Int) {
        self.autoClassifyEnabled = autoClassifyEnabled; self.thickBookThreshold = thickBookThreshold
    }
}

/// ライブラリパス再リンクリクエスト。
public struct RelinkRequest: Codable, Sendable {
    public var newPath: String
    public init(newPath: String) { self.newPath = newPath }
}

/// 重複グループ 1 件 DTO（kind: "exact"/"possible"）。
public struct DuplicateGroupDTO: Codable, Sendable {
    public var kind: String
    public var key: String
    public var members: [BookListItemDTO]
    public init(kind: String, key: String, members: [BookListItemDTO]) {
        self.kind = kind; self.key = key; self.members = members
    }
}

/// 重複スキャン結果 DTO（exact/possible グループ一覧 + 統計）。
public struct DuplicateScanReply: Codable, Sendable {
    public var exact: [DuplicateGroupDTO]
    public var possible: [DuplicateGroupDTO]
    public var candidateCount: Int
    public var hashedCount: Int
    public var missingCount: Int
    public init(exact: [DuplicateGroupDTO], possible: [DuplicateGroupDTO],
                candidateCount: Int, hashedCount: Int, missingCount: Int) {
        self.exact = exact; self.possible = possible
        self.candidateCount = candidateCount; self.hashedCount = hashedCount; self.missingCount = missingCount
    }
}
