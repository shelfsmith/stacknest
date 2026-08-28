// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

// ─────────────────────────────────────────────────────────────
// 共有 wire 型（Foundation のみ依存・Hummingbird/LibraryStore/AppCore 不使用）
// サーバ側（LibraryServer）とクライアント側（将来の App）が共通でこのモジュールを import する。
// ─────────────────────────────────────────────────────────────

/// books 一覧 1 件分の DTO（spec §3.3）。日付はサーバ共通エンコーダで ISO8601。
public struct BookListItemDTO: Codable, Sendable {
    // 差し替えコピー（下の extension）を素直に書くため var。ただし setter は
    // 同一ファイル内に閉じる（`private(set)`）ので、モジュール外からは実質 let のまま。
    public private(set) var id: Int
    public private(set) var title: String
    public private(set) var author: String?
    public private(set) var series: String?
    public private(set) var volume: Double?
    public private(set) var rating: Int
    public private(set) var unseen: Bool
    public private(set) var bookType: Int
    public private(set) var pages: Int?
    public private(set) var lastPage: Int?
    public private(set) var lastReadAt: Date?
    public private(set) var dateAdded: Date
    public private(set) var hasCover: Bool
    /// 表紙差し替えを Web の `?v=` で追跡するためのバージョン文字列（thumbnail.jpg の mtime+size 由来）。
    /// 表紙なしの本は nil。stat コスト抑制のためページスライス後の本のみ算出する（run 参照）。
    public private(set) var coverVersion: String?
    /// 4.2c-6b: 表紙クロップ矩形 JSON（リモートグリッド/リストのクロップ適用用）。クロップ無しは nil。
    public private(set) var coverCropRectJSON: String?
    /// G15 V3: サーバ側ファイル basename（フルパスではない）。BuiltInViewerSupport 判定に使う。
    /// path を持たない本（folder 等）は nil。
    public private(set) var filename: String?
    // ── 動的フィールド（&fields= で要求された時のみ充填・既定 nil） ──
    public private(set) var genre: String?
    public private(set) var neta: String?
    public private(set) var keywordA: String?
    public private(set) var keywordB: String?
    public private(set) var keywordC: String?
    public private(set) var memo: String?

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
        coverCropRectJSON: String? = nil,
        filename: String? = nil
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
        self.filename = filename
    }
}

extension BookListItemDTO {
    /// coverVersion だけ差し替えたコピーを返す。
    public func withCoverVersion(_ version: String?) -> BookListItemDTO {
        var c = self; c.coverVersion = version; return c
    }

    /// 応答スライス用。fields に含まれない追加フィールドを nil に落とす。memo は 200 字に切詰。
    ///
    /// **⚠ フィールドを増やすときは必ずここにも足すこと。失敗の向きが copy-and-mutate 化で反転した。**
    /// 旧実装（全フィールドを手で再構築）で書き足しを忘れると、そのフィールドは常に**欠落**した
    /// （＝取りこぼしとして目に見える）。現在は self のコピーを削る形なので、書き足しを忘れると
    /// **`&fields=` の指定を無視して常に送信される＝意図しない漏洩**になる。
    /// ゴールデンテストが捕まえるのは、テスト側の `full` ケースにも新フィールドを足した場合だけ。
    public func keepingExtras(_ fields: Set<String>) -> BookListItemDTO {
        var c = self
        if !fields.contains("genre") { c.genre = nil }
        if !fields.contains("neta") { c.neta = nil }
        if !fields.contains("keywordA") { c.keywordA = nil }
        if !fields.contains("keywordB") { c.keywordB = nil }
        if !fields.contains("keywordC") { c.keywordC = nil }
        c.memo = fields.contains("memo") ? memo.map { String($0.prefix(200)) } : nil
        return c
    }

    /// lastPage を差し替えた複製（リモート閲覧の進捗をメモリ上の一覧へ反映し、
    /// 一覧を再取得しなくても再オープン時に続きから開くために使う）。
    public func withLastPage(_ page: Int?) -> BookListItemDTO {
        var c = self; c.lastPage = page; return c
    }

    /// unseen フラグだけ差し替えた複製（リモート閲覧で未読マーカーを楽観的に消すために使う）。
    public func withUnseen(_ v: Bool) -> BookListItemDTO {
        var c = self; c.unseen = v; return c
    }

    /// lastReadAt だけ差し替えた複製（リモート閲覧で最終閲覧日時を楽観的に更新するために使う）。
    public func withLastReadAt(_ date: Date?) -> BookListItemDTO {
        var c = self; c.lastReadAt = date; return c
    }
}

extension Array where Element == BookListItemDTO {
    /// 指定 ID の本を既読にした一覧を返す（G35b）。
    ///
    /// リモート閲覧で「開いた瞬間に一覧へ反映する」ために使う。ローカルは G34b で同じことを
    /// しており、リモートだけ**その巻を離れるまで一覧が未読のまま**だったのを揃える。
    ///
    /// **並び替えない。** 該当行の値だけ差し替える（ローカルと同じ方針。「読んだ日」降順で
    /// 並べているときに読み進めるたび先頭へジャンプするのを避ける）。
    ///
    /// **`lastPage` は触らない。** 巻送り直後の読書位置はまだ確定しておらず、
    /// 確定していない値で一覧を上書きしない（`persistState` が正しい値で更新する）。
    ///
    /// **`unseen` の状態で分岐しない。** 既読の本を読み返したときも「読んだ日」は更新すべきで、
    /// `unseen == true` のときだけ更新すると読み返しが記録されない。
    public func markingRead(bookID: Int, at date: Date) -> [BookListItemDTO] {
        guard let i = firstIndex(where: { $0.id == bookID }) else { return self }
        var out = self
        out[i] = out[i].withUnseen(false).withLastReadAt(date)
        return out
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

/// アクセス階層（read < edit < admin の 3 段）。
/// - read: R トークン（読み取り専用）
/// - edit: W トークン（通常の編集権限・adminTier=false 時）
/// - admin: W または R トークン（adminTier=true のサーバでは全トークンが admin に昇格）
public enum AccessTier: String, Codable, Sendable, Comparable {
    case read, edit, admin
    private var rank: Int { switch self { case .read: return 0; case .edit: return 1; case .admin: return 2 } }
    public static func < (l: AccessTier, r: AccessTier) -> Bool { l.rank < r.rank }
}

/// グラントが有効なライブラリスコープ（all = 全ライブラリ、libraries = UUID リスト）。
public enum GrantScope: Codable, Sendable, Equatable {
    case all
    case libraries([String])
    public func allows(_ uuid: String) -> Bool {
        switch self { case .all: return true; case .libraries(let s): return s.contains(uuid) }
    }

    // カスタム Codable: .all → {} (空オブジェクト), .libraries(uuids) → {"libraries":[...]}
    // （Swift 合成 Codable のフォーマットはワイヤー互換性が低いため独自実装）
    private enum GrantScopeCodingKeys: String, CodingKey { case libraries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GrantScopeCodingKeys.self)
        if let uuids = try container.decodeIfPresent([String].self, forKey: .libraries) {
            self = .libraries(uuids)
        } else {
            self = .all
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: GrantScopeCodingKeys.self)
        switch self {
        case .all:
            break   // 空オブジェクト {} として encode
        case .libraries(let uuids):
            try container.encode(uuids, forKey: .libraries)
        }
    }
}

/// GET /me の応答。提示トークンの tier と role（互換）、スコープを返す。
public struct MeReply: Codable, Sendable {
    public let role: TokenRole   // 互換: admin/edit→.write, read→.read
    public let tier: AccessTier
    public let scope: GrantScope
    public init(tier: AccessTier, scope: GrantScope) {
        self.tier = tier
        self.scope = scope
        self.role = (tier == .read) ? .read : .write
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
    /// G17 T6b: ページ単位のレイアウト override（page_index(String) → mode(Int, 0=forcePair/1=forceSolo)）。
    /// 後方互換のため optional・省略可。override が 1 件も無い本は nil を返す
    /// （旧クライアントはこのキー自体を知らないので単に無視する）。
    public let pageOverrides: [String: Int]?
    /// G26: 破損等で全ページを読めなかったときの注意文。
    /// **nil ならキー自体を省略する**（`pageOverrides` と同じ後方互換方針）。
    public let damageNote: String?

    public init(pageCount: Int, direction: String, format: String, etag: String,
                pageOverrides: [String: Int]? = nil, damageNote: String? = nil) {
        self.pageCount = pageCount
        self.direction = direction
        self.format = format
        self.etag = etag
        self.pageOverrides = pageOverrides
        self.damageNote = damageNote
    }
}

/// unlock 成功レスポンス（短命ライブラリトークン）。
public struct UnlockReply: Codable, Sendable {
    public let libraryToken: String

    public init(libraryToken: String) {
        self.libraryToken = libraryToken
    }
}

/// G23 (#9/#10): `POST /session` の応答。URL クエリへ載せるための短命トークン。
/// 永続の grant token を履歴やログに残さないため、クエリにはこちらだけを使う。
public struct SessionReply: Codable, Sendable {
    public let sessionToken: String
    /// 有効期間（秒）。クライアントはこれを目安に再交換する。
    public let expiresIn: Int

    public init(sessionToken: String, expiresIn: Int) {
        self.sessionToken = sessionToken
        self.expiresIn = expiresIn
    }
}

/// 棚（ユーザー定義棚 / スマート棚）の一覧 DTO（spec §3.3 /shelves）。
public struct ShelfDTO: Codable, Sendable {
    public let id: Int64
    public let title: String
    public let kind: String
    public let isSmart: Bool
    /// G13/F1: 棚の所属件数（手動棚/お気に入り=playlist 所属数、スマート棚=条件評価数）。
    /// 未提供の生成箇所（create/patch 応答等）は既定 0。
    public let bookCount: Int
    public init(id: Int64, title: String, kind: String, isSmart: Bool, bookCount: Int = 0) {
        self.id = id; self.title = title; self.kind = kind; self.isSmart = isSmart; self.bookCount = bookCount
    }
    // 後方互換: 旧レスポンス（bookCount 欠落）は 0 として decode する。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(String.self, forKey: .kind)
        isSmart = try c.decode(Bool.self, forKey: .isSmart)
        bookCount = try c.decodeIfPresent(Int.self, forKey: .bookCount) ?? 0
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
    /// G12b-3a: リモート一般タブ等での表示用ファイル名（拡張子込み）。旧サーバ/旧 JSON には無いため後方互換で nil 許容。
    public let filename: String?
    /// G16 A2: PATCH 応答限定で、今回変更されたフィールドの更新前の値（同型 BookPatchDTO・変更外は nil）。
    /// GET /detail 等の他エンドポイントでは常に nil（キー自体が JSON から省略される・旧クライアントは無視）。
    public let previous: BookPatchDTO?
    public init(id: Int, title: String, author: String?, genre: String?, path: String?,
                dateAdded: Date, playDate: Date?, bookType: Int, fileType: Int, pages: Int?,
                lastPage: Int? = nil,
                rating: Int, unseen: Bool, keywordA: String?, keywordB: String?, keywordC: String?,
                neta: String?, memo: String?, series: String?, volume: Double?,
                coverImageName: String?, coverCropRectJSON: String?, pageDirection: String?,
                fileExtension: String? = nil,
                filename: String? = nil,
                previous: BookPatchDTO? = nil) {
        self.id = id; self.title = title; self.author = author; self.genre = genre; self.path = path
        self.dateAdded = dateAdded; self.playDate = playDate; self.bookType = bookType
        self.fileType = fileType; self.pages = pages; self.lastPage = lastPage
        self.rating = rating; self.unseen = unseen
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.neta = neta; self.memo = memo; self.series = series; self.volume = volume
        self.coverImageName = coverImageName; self.coverCropRectJSON = coverCropRectJSON
        self.pageDirection = pageDirection
        self.fileExtension = fileExtension
        self.filename = filename
        self.previous = previous
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
    /// G9: サブフォルダの扱い。AppCore.WatchedFolder.SubfolderMode と同 raw 値（DTO 層は AppCore を import 不可）。
    public enum SubfolderMode: String, Codable, Sendable {
        case topLevelOnly
        case archive
        case recurse
    }
    public var id: String
    public var path: String
    public var enabled: Bool
    public var presetID: String?
    public var baseline: [String]
    public var subfolderMode: SubfolderMode
    public init(id: String, path: String, enabled: Bool, presetID: String? = nil,
                baseline: [String] = [], subfolderMode: SubfolderMode = .topLevelOnly) {
        self.id = id; self.path = path; self.enabled = enabled
        self.presetID = presetID; self.baseline = baseline; self.subfolderMode = subfolderMode
    }
    private enum CodingKeys: String, CodingKey { case id, path, enabled, presetID, baseline, subfolderMode }
    // 後方互換: 旧 JSON（subfolderMode 欠落）は .topLevelOnly。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        baseline = try c.decodeIfPresent([String].self, forKey: .baseline) ?? []
        subfolderMode = try c.decodeIfPresent(SubfolderMode.self, forKey: .subfolderMode) ?? .topLevelOnly
    }
}

/// 命名プリセット 1 件の DTO（watch-config の名前選択用途は format 省略、
/// G12b-3c の presets GET/PUT は format も搬送する）。
/// format は後方互換のため optional（旧クライアント/watch-config は name のみ送信）。
public struct FilenameFormatPresetDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var format: String?
    public init(id: String, name: String, format: String? = nil) {
        self.id = id; self.name = name; self.format = format
    }
}

/// 一般タブ設定（ライブラリ名＋バックアップ設定）。
public struct GeneralSettingsDTO: Codable, Sendable {
    public var displayName: String       // 空文字 = 未設定（バンドル名にフォールバック）
    public var backupEnabled: Bool
    public var backupGenerations: Int
    public init(displayName: String, backupEnabled: Bool, backupGenerations: Int) {
        self.displayName = displayName; self.backupEnabled = backupEnabled
        self.backupGenerations = backupGenerations
    }
}

/// SQLite integrity_check の結果。
public struct IntegrityCheckDTO: Codable, Sendable {
    public var healthy: Bool
    public var rows: [String]
    public init(healthy: Bool, rows: [String]) { self.healthy = healthy; self.rows = rows }
}

/// 監視フォルダ設定全体の DTO（enabled フラグ＋フォルダ一覧）。
public struct WatchConfigDTO: Codable, Sendable {
    public var enabled: Bool
    public var folders: [WatchedFolderDTO]
    /// GET 専用。ライブラリの命名プリセット一覧（リモート Picker の名前表示用）。PUT では無視。
    public var presets: [FilenameFormatPresetDTO]?
    public init(enabled: Bool, folders: [WatchedFolderDTO], presets: [FilenameFormatPresetDTO]? = nil) {
        self.enabled = enabled; self.folders = folders; self.presets = presets
    }
}

/// G12b-3c: 既存フォルダ一括再取込リクエスト（対象 folder の baseline をクリアして scan）。
public struct ImportExistingRequest: Codable, Sendable {
    public var folderID: String
    public init(folderID: String) { self.folderID = folderID }
}

/// ライブラリロック設定リクエスト（パスワード設定・変更）。
/// G27a Task6: `currentPassword` は既存ロックの**変更時のみ必須**（新規設定時は省略可＝nil）。
/// サーバは既存ハッシュがあるときだけこのフィールドを検証する（無ければ従来どおり無検証で新規設定できる）。
public struct LockRequest: Codable, Sendable {
    public var password: String
    public var currentPassword: String?
    public init(password: String, currentPassword: String? = nil) {
        self.password = password
        self.currentPassword = currentPassword
    }
}

/// ライブラリロック解除リクエスト（G27a Task6）。DELETE のボディとして送る — このリポジトリでは
/// `DELETE libraries/:lib/shelves/:id/books` が既に body 付き DELETE を使っており新しい作法ではない。
/// `currentPassword` は既存ロックがあるときだけ必須。ロックが無ければボディ自体を省略してよい
/// （サーバは空ボディを「現パスワード無し」として扱い、後方互換を保つ）。
public struct LockRemoveRequest: Codable, Sendable {
    public var currentPassword: String?
    public init(currentPassword: String? = nil) { self.currentPassword = currentPassword }
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

/// 重複グループ 1 件 DTO（kind: "exact"/"possibleSeriesVolume"）。
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

/// 整合性検査の集計（G27a）。
public struct IntegritySummaryReply: Codable, Sendable {
    public let checked: Int
    public let unchecked: Int
    public let damaged: Int
    public let degraded: Int
    /// 最終検査時刻（epoch seconds）。2026-08-08 smoke フィードバックで追加 ―― **旧サーバ
    /// （このフィールドを知らないビルド）はキー自体を応答に含めない。** 新サーバは「一度も
    /// 検査していない」場合でも `null` を明示して必ずキーを送る（`encode(to:)` 参照）。
    /// `nil` だけでは「新サーバが『未検査』と答えた」のか「旧サーバがそもそも運ばない」のか
    /// 区別できない（`Optional` の `decodeIfPresent` はキー欠落と明示 `null` を区別しない）ため、
    /// その判定材料は `lastScanAtKnown` が担う ―― **この 2 フィールドは必ずセットで見ること**。
    public let lastScanAt: Int64?
    /// サーバの応答 JSON に `lastScanAt` キー自体が存在したか（＝新サーバか）。
    ///
    /// `RemoteIntegrityDataSource.supportsLastScanAt` の直接の情報源。旧サーバとの通信では
    /// 常に `false` になり、`lastScanAt == nil` が「未検査」ではなく「取得できない」（不明）と
    /// 表示されるようにする ―― このブランチが 6 ラウンドかけて除去した「読めなかったことを
    /// 事実として断言する」欠陥（施錠庫を『破損 0 冊』と表示していた等）の再演を避けるため。
    public let lastScanAtKnown: Bool

    private enum CodingKeys: String, CodingKey {
        case checked, unchecked, damaged, degraded, lastScanAt
    }

    /// サーバ側・テスト側から直接組み立てる用。新サーバが答える値は常に「分かっている」ので
    /// `lastScanAtKnown` は既定 `true`（旧サーバのシミュレートには `init(from:)` 経由で
    /// キーを欠いた JSON を渡すこと）。
    public init(checked: Int, unchecked: Int, damaged: Int, degraded: Int,
                lastScanAt: Int64? = nil, lastScanAtKnown: Bool = true) {
        self.checked = checked; self.unchecked = unchecked
        self.damaged = damaged; self.degraded = degraded
        self.lastScanAt = lastScanAt; self.lastScanAtKnown = lastScanAtKnown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = try c.decode(Int.self, forKey: .checked)
        unchecked = try c.decode(Int.self, forKey: .unchecked)
        damaged = try c.decode(Int.self, forKey: .damaged)
        degraded = try c.decode(Int.self, forKey: .degraded)
        // `contains` で「キーが存在するか」を明示的に見る。`decodeIfPresent` だけでは
        // 「キー欠落」と「値が null」を区別できず、旧サーバの沈黙を「未検査」と誤読しかねない。
        if c.contains(.lastScanAt) {
            lastScanAt = try c.decodeIfPresent(Int64.self, forKey: .lastScanAt)
            lastScanAtKnown = true
        } else {
            lastScanAt = nil
            lastScanAtKnown = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(checked, forKey: .checked)
        try c.encode(unchecked, forKey: .unchecked)
        try c.encode(damaged, forKey: .damaged)
        try c.encode(degraded, forKey: .degraded)
        // Codex レビュー(Important): 復号は「キーが無い＝旧サーバが知らない」と
        // 「キーはあるが null＝新サーバが答えたうえで未検査」を区別しているのに、
        // 符号化が `lastScanAtKnown` を無視して常にキーを出していた。
        // そのため**旧サーバの応答を復号して再符号化すると、意味が「未検査」に変わる**
        // （プロキシ・キャッシュ・フィクスチャ等、復号→再符号化を挟む経路で壊れる）。
        // 直接の表示経路は再符号化しないので実害は出ていなかったが、
        // 型が主張している区別が片方向でしか成立していないのは、まさに本ブランチが
        // 繰り返し潰してきた「知らないことを、知っている値の顔にする」欠陥である。
        //
        // 「知っている」ときだけキーを出す。`encodeIfPresent` ではなく `encode` を使うのは、
        // `Optional<Int64>` の `Encodable` 適合が nil を「キーはあるが値は null」として
        // 符号化するため ―― 「答えたうえで未検査」を表現するのに必要。
        if lastScanAtKnown {
            try c.encode(lastScanAt, forKey: .lastScanAt)
        }
    }
}

/// 簡易スキャンの実行結果（G27a）。
///
/// `persistenceFailures` は byStatus のどこにも計上されなかった（DB 書き込みに失敗した）冊数。
/// `ok + damaged + empty + missing + unsupported + persistenceFailures == scanned` が常に成り立つ。
public struct IntegrityScanReply: Codable, Sendable {
    public let scanned: Int
    public let ok: Int
    public let damaged: Int
    public let empty: Int
    public let missing: Int
    public let unsupported: Int
    public let pagesUpdated: Int
    public let persistenceFailures: Int
    public init(scanned: Int, ok: Int, damaged: Int, empty: Int,
                missing: Int, unsupported: Int, pagesUpdated: Int, persistenceFailures: Int) {
        self.scanned = scanned; self.ok = ok; self.damaged = damaged
        self.empty = empty; self.missing = missing
        self.unsupported = unsupported; self.pagesUpdated = pagesUpdated
        self.persistenceFailures = persistenceFailures
    }
}

public struct IntegrityItemDTO: Codable, Sendable {
    public let bookID: Int
    public let title: String
    /// path は秘匿で返さないため、ファイル名（basename）だけを返す（read tier でも取得できる
    /// エンドポイントのため、path をそのまま返すとディレクトリ構成が漏れる）。
    public let filename: String?
    public let status: String
    public let checkedAt: Int64
    public let entryCount: Int?
    public let badEntries: [String]
    /// 前回 ok → 今回 damaged（＝ディスク上で劣化した疑い）。
    public let degraded: Bool
    public init(bookID: Int, title: String, filename: String?, status: String,
                checkedAt: Int64, entryCount: Int?, badEntries: [String], degraded: Bool) {
        self.bookID = bookID; self.title = title; self.filename = filename
        self.status = status; self.checkedAt = checkedAt
        self.entryCount = entryCount; self.badEntries = badEntries; self.degraded = degraded
    }
}

public struct IntegrityListReply: Codable, Sendable {
    public let items: [IntegrityItemDTO]
    public init(items: [IntegrityItemDTO]) { self.items = items }
}

// MARK: - B2b: グラント CRUD DTO

/// グラント 1 件の応答 DTO（token は作成時のみ全文字列を返す・一覧は将来マスクする）。
public struct GrantDTO: Codable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public let tier: AccessTier
    public let scope: GrantScope
    public init(id: String, label: String, token: String, tier: AccessTier, scope: GrantScope) {
        self.id = id; self.label = label; self.token = token; self.tier = tier; self.scope = scope
    }
}

/// POST /api/v1/grants リクエスト。
public struct GrantCreateRequest: Codable, Sendable {
    public var label: String
    public var tier: AccessTier
    public var scope: GrantScope
    public init(label: String, tier: AccessTier, scope: GrantScope) {
        self.label = label; self.tier = tier; self.scope = scope
    }
}

// MARK: - G14: リモートサイドバー安定件数

/// リモートサイドバーの安定件数（現在の browse scope に依存しない）。
public struct LibraryCountsDTO: Codable, Sendable {
    public var libraryTotal: Int
    public var recentCount: Int
    public var recentDays: Int
    public init(libraryTotal: Int, recentCount: Int, recentDays: Int = 14) {
        self.libraryTotal = libraryTotal; self.recentCount = recentCount; self.recentDays = recentDays
    }
}

// MARK: - G27b: メンテナンス進捗照会

/// GET libraries/:lib/maintenance/status 応答。31 時間規模のフルスキャンなど長時間ジョブを、
/// SSE を張り続けずに問い合わせられるようにする（registry が保持する最新進捗をそのまま運ぶ）。
public struct MaintenanceStatusReply: Codable, Sendable, Equatable {
    public var running: Bool
    public var job: String?
    public var done: Int?
    public var total: Int?
    /// epoch 秒。実行中でなければ nil。
    public var startedAt: Int64?
    public init(running: Bool, job: String? = nil, done: Int? = nil, total: Int? = nil, startedAt: Int64? = nil) {
        self.running = running; self.job = job; self.done = done; self.total = total; self.startedAt = startedAt
    }
}

/// POST libraries/:lib/integrity/full-scan の起動リクエスト（Phase G27b Task 5）。
/// `mode` は "unchecked" / "all" / "damaged" のいずれか。不明な値はサーバが 400 で拒否する
/// （既定値へ黙って落とさない — CLI/MCP の指定ミスを気づかせるため）。
public struct FullScanStartRequest: Codable, Sendable, Equatable {
    public var mode: String
    public init(mode: String) { self.mode = mode }
}

// MARK: - G12b-3c: リモート命名プリセット集合 GET/PUT

/// 命名プリセット集合＋既定 id（GET/PUT libraries/:lib/presets 用）。
public struct PresetSetDTO: Codable, Sendable, Equatable {
    public var presets: [FilenameFormatPresetDTO]
    public var defaultID: String
    public init(presets: [FilenameFormatPresetDTO], defaultID: String) {
        self.presets = presets; self.defaultID = defaultID
    }
}

// MARK: - G12b-3c S5: リモート undo（削除→復元）

/// DELETE libraries/:lib/books/:id 応答 ＋ POST libraries/:lib/books/restore の body 要素 DTO。
/// BookRow の全フィールドを可逆的に運ぶ（往復での欠落を避けるため memberwise で全部保持する）。
/// Date は epoch 秒（Double）、CGRect は x/y/w/h の 4 optional、PageDirection は
/// "ltr"/"rtl" 文字列（BookDetailDTO / directionString(_:) と同じ規約）に写像する。
public struct BookRestoreDTO: Codable, Sendable {
    public var id: Int
    public var title: String
    public var author: String?
    public var genre: String?
    public var path: String?
    public var dateAdded: Double
    public var playDate: Double?
    public var bookType: Int
    public var fileType: Int
    public var pages: Int?
    public var rating: Int
    public var unseen: Bool
    public var keywordA: String?
    public var keywordB: String?
    public var keywordC: String?
    public var neta: String?
    public var memo: String?
    public var series: String?
    public var volume: Double?
    public var coverImageName: String?
    public var coverCropX: Double?
    public var coverCropY: Double?
    public var coverCropW: Double?
    public var coverCropH: Double?
    public var pageDirection: String?
    public var contentHash: String?
    public var fileSize: Int64?
    public var fileMtime: Double?
    /// G12b-3d smoke fix: 削除時点で表紙（Thumbnails/<id>/thumbnail.jpg）が存在したか。restore 時にこれが
    /// true の本のみサムネイルをソースアーカイブから再生成する（ローカル undo の「DB 復元＋file regenerate」と parity）。
    /// Optional にして後方互換（キー欠落の旧ペイロード＝nil＝無表紙扱いの安全側）を確保する（Codex G12b-3d Medium）。
    public var hasCover: Bool?

    public init(
        id: Int, title: String, author: String?, genre: String?, path: String?,
        dateAdded: Double, playDate: Double?, bookType: Int, fileType: Int, pages: Int?,
        rating: Int, unseen: Bool,
        keywordA: String?, keywordB: String?, keywordC: String?,
        neta: String?, memo: String?, series: String?, volume: Double?,
        coverImageName: String?,
        coverCropX: Double? = nil, coverCropY: Double? = nil, coverCropW: Double? = nil, coverCropH: Double? = nil,
        pageDirection: String? = nil,
        contentHash: String? = nil, fileSize: Int64? = nil, fileMtime: Double? = nil,
        hasCover: Bool? = nil
    ) {
        self.id = id; self.title = title; self.author = author; self.genre = genre; self.path = path
        self.dateAdded = dateAdded; self.playDate = playDate
        self.bookType = bookType; self.fileType = fileType; self.pages = pages
        self.rating = rating; self.unseen = unseen
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.neta = neta; self.memo = memo; self.series = series; self.volume = volume
        self.coverImageName = coverImageName
        self.coverCropX = coverCropX; self.coverCropY = coverCropY
        self.coverCropW = coverCropW; self.coverCropH = coverCropH
        self.pageDirection = pageDirection
        self.contentHash = contentHash; self.fileSize = fileSize; self.fileMtime = fileMtime
        self.hasCover = hasCover
    }
}

/// G16 A1: `POST books/restore` の応答。何件が実際に復元されたか（id 衝突でスキップされた行を除く）を
/// クライアントへ返し、`restored == 0` のとき UI が「取り消せませんでした」を表示できるようにする。
/// G16 Codex Critical: `restoredIDs` は実際に復元できた book id の一覧（id 衝突でスキップされた行・
/// path 検証で復元自体を見送った行を除く）。部分復元のとき、クライアントの redo（再削除）が
/// 「復元されなかった id」まで巻き込んで再利用先の別の本を誤って消さないよう、redo はこの一覧に
/// 含まれる id だけを対象にする。restored/requested は互換のため残す。
public struct RestoreResultDTO: Codable, Sendable {
    public var restored: Int
    public var requested: Int
    public var restoredIDs: [Int]

    public init(restored: Int, requested: Int, restoredIDs: [Int] = []) {
        self.restored = restored
        self.requested = requested
        self.restoredIDs = restoredIDs
    }

    private enum CodingKeys: String, CodingKey { case restored, requested, restoredIDs }
    // 後方互換: restoredIDs を持たない旧サーバ応答は空配列扱い（decode 失敗させない）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restored = try c.decode(Int.self, forKey: .restored)
        requested = try c.decode(Int.self, forKey: .requested)
        restoredIDs = try c.decodeIfPresent([Int].self, forKey: .restoredIDs) ?? []
    }
}

/// PATCH /api/v1/grants/:id リクエスト。nil = 変更しない。
public struct GrantUpdateRequest: Codable, Sendable {
    public var label: String?
    public var tier: AccessTier?
    public var scope: GrantScope?
    public init(label: String? = nil, tier: AccessTier? = nil, scope: GrantScope? = nil) {
        self.label = label; self.tier = tier; self.scope = scope
    }
}

// MARK: - G27b Task7: ローカル制御専用のライブラリ開閉（127.0.0.1 限定・共有サーバには出さない）

/// POST /local/libraries/open のリクエストボディ。path はローカルファイルシステム上の絶対パス。
public struct OpenLibraryRequest: Codable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// POST /local/libraries/open の応答。開いた（または既に開いていた）ライブラリの UUID。
public struct OpenLibraryReply: Codable, Sendable {
    public var uuid: String
    public init(uuid: String) { self.uuid = uuid }
}

/// POST /local/libraries/close のリクエストボディ。
public struct CloseLibraryRequest: Codable, Sendable {
    public var uuid: String
    public init(uuid: String) { self.uuid = uuid }
}

// MARK: - G39: Finder タグ同期のローカル制御（CLI/MCP）

/// GET /local/libraries/:uuid/finder-tags の応答。
///
/// **稼働中のアプリが持っている状態をそのまま映す。**DB を直接読んで組み立てるのではない ——
/// 「施錠されているか」「今走っているか」はアプリ側にしか無く、そこを別経路で作り直すと
/// 必ず食い違う（G39 の Critical は 2 件ともゲートが実作業と別の場所にあったことが原因）。
public struct FinderTagSyncStatusReply: Codable, Sendable, Equatable {
    /// 同期対象の列名（`keyword_a` など）。nil＝同期しない。
    public var field: String?
    /// 今この庫の同期が走っているか。
    public var running: Bool
    /// 施錠中か（true なら再照合は断られる）。
    public var locked: Bool
    public init(field: String?, running: Bool, locked: Bool) {
        self.field = field
        self.running = running
        self.locked = locked
    }
}

/// PUT /local/libraries/:uuid/finder-tags のリクエストボディ。
///
/// `field` が nil または空文字なら「同期しない」。**知らない列名は 400 で弾く**（黙って
/// 「同期しない」に落とさない）—— `keyword_b` を `keyword_bb` と打ち間違えたときに
/// 同期が静かに切れ、しかも前回同期値まで消える（`FinderTagSyncSetting.update` が消す）のは
/// 取り返しがつかない。
public struct FinderTagSyncFieldRequest: Codable, Sendable {
    public var field: String?
    public init(field: String?) { self.field = field }
}

/// POST /local/libraries/:uuid/finder-tags/resync の応答。
///
/// `status` は「始まったか、始まらなかったならなぜか」（App 層の `FinderTagSyncStart` の生値）。
/// **`started` 以外のとき件数はすべて 0** —— 走っていないので当然だが、
/// 「変化なし」と「断られた」を件数だけで見分けようとすると必ず取り違える。
public struct FinderTagResyncReply: Codable, Sendable, Equatable {
    /// started / alreadyRunning / noLibrary / noField / locked
    public var status: String
    /// 同期対象の列名（断られた場合も、分かっていれば入れる）。
    public var field: String?
    public var updatedInLibrary: Int
    public var updatedInFinder: Int
    /// 区切り文字（`", "`）を含むため同期しなかったタグ名。
    public var skippedTags: [String]
    /// タグを読めなかった本のパス。
    public var skippedBooks: [String]
    /// Spotlight 索引が無効だったボリューム名。**空でなければ Finder → 庫の方向は動いていない。**
    public var indexingDisabledVolumes: [String]
    /// 同期そのものが失敗した理由（表示用）。nil なら失敗していない。
    public var failure: String?

    public init(status: String, field: String? = nil,
                updatedInLibrary: Int = 0, updatedInFinder: Int = 0,
                skippedTags: [String] = [], skippedBooks: [String] = [],
                indexingDisabledVolumes: [String] = [], failure: String? = nil) {
        self.status = status
        self.field = field
        self.updatedInLibrary = updatedInLibrary
        self.updatedInFinder = updatedInFinder
        self.skippedTags = skippedTags
        self.skippedBooks = skippedBooks
        self.indexingDisabledVolumes = indexingDisabledVolumes
        self.failure = failure
    }
}

// MARK: - G47: メタデータでのファイル名変更（ローカル制御専用）

/// POST /local/libraries/:uuid/rename-files のリクエストボディ。
///
/// **`apply` が true でない限りファイルは 1 つも動かない。**既定は計画を返すだけ。
/// **`apply` キー自体は省略できない** —— `Codable` の合成イニシャライザにデフォルト値は
/// 反映されないため、JSON から `apply` を省くとデコードが失敗し **400** になる（この動作は
/// 安全側なので変更しない。呼び出し側は必ず `apply` を明示すること）。
/// `presetID` と `format` は**どちらか一方だけ**（両方来たら 400）。
/// どちらも無ければ庫の既定プリセットを使う。
public struct RenameFilesRequest: Codable, Sendable {
    public var ids: [Int]
    public var presetID: String?
    public var format: String?
    public var apply: Bool

    public init(ids: [Int], presetID: String? = nil, format: String? = nil, apply: Bool = false) {
        self.ids = ids; self.presetID = presetID; self.format = format; self.apply = apply
    }
}

/// 改名 1 冊分の結果。
public struct RenamePlanRowDTO: Codable, Sendable, Equatable {
    public var id: Int
    public var oldName: String
    public var newName: String
    /// ok / unchanged / conflictExisting / conflictInBatch / emptyName / tooLong / noPath
    public var status: String
    /// 実行して失敗したときの理由。計画だけのときは nil。
    public var failure: String?

    public init(id: Int, oldName: String, newName: String, status: String, failure: String? = nil) {
        self.id = id; self.oldName = oldName; self.newName = newName
        self.status = status; self.failure = failure
    }
}

/// POST /local/libraries/:uuid/rename-files の応答。
///
/// `status` が `ok` 以外のとき `rows` は空で `applied` は 0。
/// **庫に無い ID は `rows` に混ぜず `missingIDs` に入れる** ——
/// 「改名できなかった本」と「そもそも居ない本」は別の話で、混ぜると呼び出し側が気づけない。
public struct RenameFilesReply: Codable, Sendable, Equatable {
    /// ok / locked / badFormat / failed
    ///
    /// 庫が開いていないときは本文を返さず **HTTP 404** に落ちる（`noLibrary` という値の本文は存在しない）。
    public var status: String
    /// 実際にファイルを動かしたか（false なら計画のみ）。
    public var applied: Bool
    public var rows: [RenamePlanRowDTO]
    public var missingIDs: [Int]
    /// 改名した件数（applied が false なら 0）。
    public var renamed: Int
    /// 改名しなかった件数（ok 以外の行 ＋ 失敗した行）。
    public var skipped: Int
    /// `status == "failed"` のときだけ入る、失敗の理由（表示用）。
    /// **`badFormat` と分けてあるのは、書式の誤りと DB/ディスクの障害を混ぜないため** ——
    /// 混ぜると呼び出し側が「書式を直せば直る」と誤解する。
    public var failure: String?

    public init(status: String, applied: Bool = false, rows: [RenamePlanRowDTO] = [],
                missingIDs: [Int] = [], renamed: Int = 0, skipped: Int = 0, failure: String? = nil) {
        self.status = status; self.applied = applied; self.rows = rows
        self.missingIDs = missingIDs; self.renamed = renamed; self.skipped = skipped
        self.failure = failure
    }
}
