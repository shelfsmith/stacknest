// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import ArchiveAdapter
import Hummingbird
import LibraryServerAPI

/// LibraryServer の設定（4.1b でアプリ設定 UI から渡される）。
public struct LibraryServerConfig: Sendable {
    public var host: String
    public var port: Int
    /// デバイス認証用の共有トークン（QR でクライアントに渡す）。読み取り（R）ロール。
    public var token: String
    /// 編集（RW）ロール用トークン。未生成は nil（その場合 RW 認証はできず R のみ）。
    public var editToken: String?
    /// 画像縮小器（既定は縮小しない Passthrough）。App は ImageIOTranscoder を注入する。
    public var transcoder: any ImageTranscoding
    /// 本ごと pageDirection が未設定のときの既定方向（アプリ起動時にスナップショット）。
    /// manifest エンドポイントが null を返さずに実効方向を返すために使う（4.1c）。
    public var defaultPageDirection: PageDirection
    /// 本のメタデータをサーバ経由で変更したとき App に通知する（libraryUUID, bookID）。
    /// App は該当ライブラリのインメモリ本モデルを DB から更新して GUI（詳細ペイン等）へ反映する。
    public var onBookChanged: (@Sendable (String, Int) -> Void)?
    /// 4.2c-6a: ライブラリ設定（スタンプ定義など）をサーバ経由で変更したとき App に通知する
    /// （libraryUUID）。App は該当ライブラリのインメモリ設定を DB から再読込して GUI に反映する。
    public var onLibrarySettingsChanged: (@Sendable (String) -> Void)?
    /// 取り込み時の自動分類設定（POST /books が BookImporter に渡す）。アプリは ViewerSettings から、
    /// 将来のヘッドレスは自前の値から注入する（global を読まない）。
    public var autoClassifyEnabled: Bool
    public var thickThreshold: Int
    /// 実ファイルをゴミ箱へ送る注入関数（macOS は FileManager.trashItem を注入）。
    /// nil のとき DELETE ?trash=true は拒否（Linux/ヘッドレス portable のため core は直接 trash しない）。
    public var trashFile: (@Sendable (URL) throws -> Void)?
    // dual-stack 化は呼び出し側が host: "::" を明示注入する
    // （Linux は v6only sysctl 依存のため既定は互換性優先の 0.0.0.0）。
    public init(host: String = "0.0.0.0", port: Int, token: String,
                editToken: String? = nil,
                transcoder: any ImageTranscoding = PassthroughTranscoder(),
                defaultPageDirection: PageDirection = .rightToLeft,
                onBookChanged: (@Sendable (String, Int) -> Void)? = nil,
                onLibrarySettingsChanged: (@Sendable (String) -> Void)? = nil,
                autoClassifyEnabled: Bool = false,
                thickThreshold: Int = 0,
                trashFile: (@Sendable (URL) throws -> Void)? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.editToken = editToken
        self.transcoder = transcoder
        self.defaultPageDirection = defaultPageDirection
        self.onBookChanged = onBookChanged
        self.onLibrarySettingsChanged = onLibrarySettingsChanged
        self.autoClassifyEnabled = autoClassifyEnabled
        self.thickThreshold = thickThreshold
        self.trashFile = trashFile
    }
}

/// LibraryServer 共通の RequestContext。JSON の Date を ISO8601 に固定する
/// （Hummingbird 2.25 の既定も ISO8601 だが、upstream の既定変更に依存しないよう明示。
/// テスト側デコーダも .iso8601 で一致させること — plan 設計ノート）。
public struct LibraryRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// 提示トークンのロール。BearerAuthMiddleware が認証成功時に刻む（既定 .read）。
    public var role: TokenRole = .read

    public init(source: Source) {
        self.coreContext = .init(source: source)
    }

    public var requestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public var responseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// BearerAuthMiddleware が値型コンテキストへロールを刻めるよう、role を get/set 可能にする制約。
/// 認証ミドルウェアはこの protocol への準拠だけを要求し、具体コンテキストに依存しない。
public protocol RoleHoldingContext { var role: TokenRole { get set } }
extension LibraryRequestContext: RoleHoldingContext {}

/// ファセット / ブラウズで受け付ける列名の許可リスト（SQL injection 防御・4.2b-1b-2b）。
/// BrowserPaneState.BrowseField.allCases から生成するため enum の変更に自動追従する。
let allowedFacetColumns: Set<String> = Set(
    BrowserPaneState.BrowseField.allCases.map { $0.sqlColumn }
)

/// HTTP サーバ本体。Router 構築と Application 生成を担う。
/// AppKit / ImageIO / PDFKit を import しないこと（Linux 移植規律・spec §3.2）。
public struct LibraryServerCore: Sendable {
    public let config: LibraryServerConfig
    let dataSource: any LibraryServerDataSource
    /// ロック庫の短命トークン（メモリのみ・再起動で失効）。
    let tokenStore = LibraryTokenStore()
    /// 本ごとの BookContent ハンドルキャッシュ（アーカイブ再オープン排除・spec §3.3）。
    let contentCache = BookContentCache(ttlSeconds: 300)

    public init(config: LibraryServerConfig, dataSource: any LibraryServerDataSource) {
        self.config = config
        self.dataSource = dataSource
    }

    public func buildApplication() -> some ApplicationProtocol {
        let router = Router(context: LibraryRequestContext.self)
        // /server/info は認証不要（ペアリング前の到達性確認用）。
        let transcodes = config.transcoder.supportsScaling
        router.get("/api/v1/server/info") { _, _ in
            var caps = ServerCapabilities.inApp
            caps.transcode = transcodes
            return caps
        }
        // それ以外の API は Bearer トークン認証配下。
        let api = router.group("api/v1")
            .add(middleware: BearerAuthMiddleware(token: config.token, editToken: config.editToken))
        let dataSource = self.dataSource
        let tokenStore = self.tokenStore
        let resolver = LibraryResolver(dataSource: dataSource, tokenStore: tokenStore)
        // 提示トークンのロール（read / write）を返す。RW ゲート編集の前段確認に使う（4.2b-3）。
        api.get("me") { _, context in
            MeReply(role: context.role)
        }
        api.get("libraries") { _, _ in
            let libs = await dataSource.servedLibraries()
            return libs.map {
                LibraryDTO(id: $0.uuid, name: $0.name, locked: $0.isLocked,
                           bookCount: (try? $0.db.fetchBookCount()) ?? 0)
            }
        }
        // ロック庫の解錠: パスワード照合に成功したら短命ライブラリトークンを発行。
        // 注意: Body/Reply はファイルスコープに置く（クロージャ内ローカル型を戻り値にすると
        // swiftc の ASTMangler が無限再帰でクラッシュするため）。
        api.post("libraries/:lib/unlock") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = await dataSource.servedLibraries().first(where: { $0.uuid == uuid }) else {
                throw HTTPError(.notFound)
            }
            let body = try await request.decode(as: UnlockRequestBody.self, context: context)
            guard lib.verifyPassword(body.password) else { throw HTTPError(.forbidden) }
            return UnlockReply(libraryToken: await tokenStore.issueToken(for: uuid))
        }
        // books 一覧（ページング・検索・ソート・進行状況・scope/filter/browse）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
            ) else {
                throw HTTPError(.notFound)
            }
            let qp = request.uri.queryParameters
            let sortRaw = qp.get("sort") ?? "title"
            guard let sort = BookSortKey(rawValue: sortRaw) else { throw HTTPError(.badRequest) }
            // order は明示時のみ尊重。不正値（asc/desc 以外）は 400。
            let order: SortOrder
            if let orderRaw = qp.get("order") {
                guard let o = SortOrder(rawValue: orderRaw) else { throw HTTPError(.badRequest) }
                order = o
            } else {
                order = sort.defaultOrder
            }
            // ?filter=<URL-encoded JSON FilterState> — decode or use empty default.
            let filter = decodeFilterState(from: qp.get("filter"))
            // ?browse=<URL-encoded JSON [[column,value]]> — 不正列名は 400（SQL injection 防御）。
            let browse = try decodeBrowseConstraintsValidated(from: qp.get("browse"))
            // ?fields=genre,neta,... — 応答に追加する任意フィールド（許可外は無視）。
            let allowedFields: Set<String> = ["genre", "neta", "keywordA", "keywordB", "keywordC", "memo"]
            let extraFields = Set((qp.get("fields") ?? "")
                .split(separator: ",").map(String.init)).intersection(allowedFields)
            let query = BooksQuery(
                q: qp.get("q"),
                sort: sort,
                order: order,
                page: max(1, qp.get("page", as: Int.self) ?? 1),
                per: min(500, max(1, qp.get("per", as: Int.self) ?? 100)),
                scope: decodeSidebarScope(scope: qp.get("scope"), scopeId: qp.get("scopeId", as: Int64.self), recentDays: qp.get("recentDays", as: Int.self)),
                filter: filter,
                browse: browse,
                extraFields: extraFields
            )
            return try query.run(on: lib)
        }
        // 棚一覧（ユーザー棚・スマート棚）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/shelves") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
            ) else {
                throw HTTPError(.notFound)
            }
            let rows = try lib.db.fetchAllShelves()
            return rows.map { row in
                ShelfDTO(id: row.id, title: row.title, kind: row.kind, isSmart: row.isSmart)
            }
        }
        // ファセット（列の distinct 値リスト）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/facets/:field") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
            ) else {
                throw HTTPError(.notFound)
            }
            let field = try context.parameters.require("field")
            guard allowedFacetColumns.contains(field) else { throw HTTPError(.badRequest) }
            let qp = request.uri.queryParameters
            let filter = decodeFilterState(from: qp.get("filter"))
            let browse = try decodeBrowseConstraintsValidated(from: qp.get("browse"))
            let values = try lib.db.distinctValues(
                forColumn: field,
                query: qp.get("q") ?? "",
                sidebarScope: decodeSidebarScope(scope: qp.get("scope"), scopeId: qp.get("scopeId", as: Int64.self), recentDays: qp.get("recentDays", as: Int.self)),
                filter: filter,
                browserConstraints: browse.map { (column: $0.0, value: $0.1) }
            )
            return values
        }
        // BookRow → BookDetailDTO 変換ヘルパ（/detail と PATCH エンドポイントで共用）。
        @Sendable func makeBookDetailDTO(from row: BookRow, lastPage: Int? = nil) -> BookDetailDTO {
            BookDetailDTO(
                id: row.id, title: row.title, author: row.author, genre: row.genre, path: nil,
                dateAdded: row.dateAdded, playDate: row.playDate, bookType: row.bookType,
                fileType: row.fileType, pages: row.pages, lastPage: lastPage,
                rating: row.rating, unseen: row.unseen,
                keywordA: row.keywordA, keywordB: row.keywordB, keywordC: row.keywordC,
                neta: row.neta, memo: row.memo, series: row.series, volume: row.volume,
                coverImageName: row.coverImageName,
                coverCropRectJSON: row.coverCropRect.map(BookRow.encodeCoverCropRect),
                pageDirection: row.pageDirection.map { directionString($0) },
                // 4.2c-6b: path 自体は秘匿。拡張子だけ返してリモートの「ファイル形式」表示に使う。
                fileExtension: row.path.map { ($0 as NSString).pathExtension.lowercased() }
            )
        }

        // 書籍詳細（フル BookRow の全フィールドを BookDetailDTO として返す）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books/:id/detail") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let lastPage = (try? lib.db.loadViewerState(bookID: row.id))?.lastPage
            return makeBookDetailDTO(from: row, lastPage: lastPage)
        }
        // 書籍メタデータ更新（RW トークン専用・表紙フィールドは対象外）。
        // role=write でなければ 403、resolve で 404/401 を返す既存ルーティングを再利用。
        api.patch("libraries/:lib/books/:id") { [config] request, context in
            guard context.role == .write else { throw HTTPError(.forbidden) }
            let (lib, row) = try await resolver.resolveBook(request, context)
            let dto = try await request.decode(as: BookPatchDTO.self, context: context)
            var patch = BookPatch()
            patch.title = dto.title
            patch.author = dto.author
            patch.genre = dto.genre
            patch.neta = dto.neta
            patch.memo = dto.memo
            patch.keywordA = dto.keywordA
            patch.keywordB = dto.keywordB
            patch.keywordC = dto.keywordC
            patch.rating = dto.rating
            patch.unseen = dto.unseen
            patch.series = dto.series
            patch.volume = dto.volume
            patch.bookType = dto.bookType
            patch.pageDirection = dto.pageDirection.flatMap { s -> PageDirection? in
                switch s {
                case "rtl": return .rightToLeft
                case "ltr": return .leftToRight
                default: return nil
                }
            }
            patch.clearSeries = dto.clearSeries
            patch.clearVolume = dto.clearVolume
            patch.clearPageDirection = dto.clearPageDirection
            try lib.db.updateBook(id: row.id, patch: patch)
            config.onBookChanged?(lib.uuid, row.id)
            let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
            return makeBookDetailDTO(from: updated)
        }
        // 4.2c-6a: スタンプ定義の取得（R）。配信バンドル設定DB の stamp_definitions を返す。
        api.get("libraries/:lib/stamp-definitions") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request)) else {
                throw HTTPError(.notFound)
            }
            let json = (try? lib.db.getLibrarySetting(key: "stamp_definitions")) ?? nil
            let map: [String: [String]] = json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            return StampDefinitionsDTO(definitions: map)
        }
        // 4.2c-6a: スタンプ定義の置換（RW）。許可カラムのみ採用しマップ全体を保存。
        api.put("libraries/:lib/stamp-definitions") { [config] request, context in
            guard context.role == .write else { throw HTTPError(.forbidden) }
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request)) else {
                throw HTTPError(.notFound)
            }
            let dto = try await request.decode(as: StampDefinitionsDTO.self, context: context)
            let allowed: Set<String> = ["genre", "neta", "keyword_a", "keyword_b", "keyword_c"]
            let filtered = dto.definitions.filter { allowed.contains($0.key) }
            let data = try JSONEncoder().encode(filtered)
            try lib.db.setLibrarySetting(key: "stamp_definitions", value: String(decoding: data, as: UTF8.self))
            // ローカル(同バンドルを開いている AppState)のインメモリ設定を再読込させる（C1' ライブ反映）。
            config.onLibrarySettingsChanged?(lib.uuid)
            return StampDefinitionsDTO(definitions: filtered)
        }
        // 4.2c-6a: 一括スタンプ適用（RW・append/clear をサーバ側で MultiValueParser/clearBookField）。
        api.post("libraries/:lib/books/stamp") { [config] request, context in
            guard context.role == .write else { throw HTTPError(.forbidden) }
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request)) else {
                throw HTTPError(.notFound)
            }
            let body = try await request.decode(as: StampApplyRequest.self, context: context)
            let updated: Int
            do {
                updated = try applyStampToBooks(db: lib.db, field: body.field, value: body.value,
                                                clear: body.clear ?? false, bookIDs: body.bookIDs)
            } catch is StampApplyError {
                throw HTTPError(.badRequest)
            }
            for id in body.bookIDs { config.onBookChanged?(lib.uuid, id) }
            return StampApplyReply(updated: updated)
        }
        // 4.2c-6b: 表紙候補（アーカイブのページ名一覧）。
        api.get("libraries/:lib/books/:id/cover-candidates") { request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            var entries: [String] = []
            if let path = row.path, let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) {
                entries = (try? await ex.listImageEntries(in: URL(fileURLWithPath: path))) ?? []
            }
            return CoverCandidatesDTO(entries: entries, current: row.coverImageName)
        }
        // 4.2c-6b: 選択ページ画像（クロップ編集プレビュー）。?name=<entry>&maxw=<px>。
        api.get("libraries/:lib/books/:id/entry-image") { [config] request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            guard let name = request.uri.queryParameters.get("name"),
                  let path = row.path,
                  let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) else {
                throw HTTPError(.notFound)
            }
            guard var data = try? await ex.extractCoverImage(from: URL(fileURLWithPath: path), preferredName: name) else {
                throw HTTPError(.notFound)
            }
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
            let etag = bookETag(for: row) + "-entry-" + String(name.hashValue)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            return cacheableImageResponse(data: data, etag: etag, request: request)
        }
        // 4.2c-6b: 表紙更新（RW）。coverImageName 更新時は thumbnail を再生成する。
        api.put("libraries/:lib/books/:id/cover") { [config] request, context in
            guard context.role == .write else { throw HTTPError(.forbidden) }
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: CoverUpdateRequest.self, context: context)
            if body.setCoverImageName {
                var patch = BookPatch()
                if let name = body.coverImageName { patch.coverImageName = name }
                else { patch.clearCoverImageName = true }
                try lib.db.updateBook(id: row.id, patch: patch)
                try await Self.regenerateThumbnail(
                    bookID: row.id, sourceURLPath: row.path, preferredName: body.coverImageName,
                    bundleURL: lib.bundleURL)
            }
            if body.setCoverCropRect {
                try lib.db.updateBookCoverCropRect(id: row.id, json: body.coverCropRect)
            }
            config.onBookChanged?(lib.uuid, row.id)
            let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
            return makeBookDetailDTO(from: updated)
        }
        // 4.2c-8: ラベルカスタマイズ取得（R 可）。未設定キーは空マップ。
        api.get("libraries/:lib/label-settings") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
            ) else {
                throw HTTPError(.notFound)
            }
            func decodeMap(_ key: String) -> [String: String] {
                guard let json = (try? lib.db.getLibrarySetting(key: key)) ?? nil,
                      let data = json.data(using: .utf8),
                      let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
                return map
            }
            return LabelSettingsDTO(
                customFieldLabels: decodeMap("custom_field_labels"),
                customBookTypeLabels: decodeMap("custom_book_type_labels"))
        }
        // 4.2c-8: ラベルカスタマイズ保存（RW 必須）。キー名・JSON 形式はローカル LibrarySettings と同一。
        api.put("libraries/:lib/label-settings") { [config] request, context in
            guard context.role == .write else { throw HTTPError(.forbidden) }
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
            ) else {
                throw HTTPError(.notFound)
            }
            let body = try await request.decode(as: LabelSettingsDTO.self, context: context)
            func encodeMap(_ map: [String: String]) -> String {
                let cleaned = map.filter { !$0.value.isEmpty }
                let data = (try? JSONEncoder().encode(cleaned)) ?? Data("{}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            try lib.db.setLibrarySetting(key: "custom_field_labels", value: encodeMap(body.customFieldLabels))
            try lib.db.setLibrarySetting(key: "custom_book_type_labels", value: encodeMap(body.customBookTypeLabels))
            config.onLibrarySettingsChanged?(lib.uuid)
            return LabelSettingsDTO(
                customFieldLabels: body.customFieldLabels.filter { !$0.value.isEmpty },
                customBookTypeLabels: body.customBookTypeLabels.filter { !$0.value.isEmpty })
        }
        // 同一シリーズの隣接巻（次/前）。サーバは全カタログを持つので未 DL でも真の隣接巻を返す。
        // 該当なしは book == nil（常に 200）。
        api.get("libraries/:lib/books/:id/adjacent") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let dir = request.uri.queryParameters.get("dir") ?? ""
            let sibling: BookRow?
            switch dir {
            case "next": sibling = try lib.db.nextVolumeInSeries(after: row)
            case "prev": sibling = try lib.db.prevVolumeInSeries(before: row)
            default: throw HTTPError(.badRequest)
            }
            let dto = sibling.map { s in
                BookListItemDTO(
                    id: s.id, title: s.title, author: s.author,
                    series: s.series, volume: s.volume,
                    rating: s.rating, unseen: s.unseen, bookType: s.bookType,
                    pages: s.pages,
                    lastPage: (try? lib.db.loadViewerState(bookID: s.id))?.lastPage,
                    lastReadAt: nil,
                    dateAdded: s.dateAdded,
                    hasCover: false, coverVersion: nil
                )
            }
            return AdjacentVolumeReply(book: dto)
        }
        // 表紙画像（ETag + immutable キャッシュ・If-None-Match で 304）。
        // ETag は表紙ファイル自身の mtime+size 由来（表紙差し替えを追跡 — 引き継ぎ(1)）。
        // 304 判定は Data(contentsOf:) の前に行う（一致時はバイト読込を省く — 4.1a Minor 解消）。
        // ?maxw= が指定された場合は ETag に幅を織り込み、縮小バイトを返す（4.1c）。
        api.get("libraries/:lib/books/:id/cover") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let url = coverURL(bundleURL: lib.bundleURL, bookID: row.id)
            let baseETag = thumbnailETag(url: url, bookID: row.id) ?? bookETag(for: row)
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            let etag = maxwETag(baseETag, maxw: maxw)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            guard var data = try? Data(contentsOf: url) else { throw HTTPError(.notFound) }
            if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
            return cacheableImageResponse(data: data, etag: etag, request: request)
        }
        // 本のマニフェスト（ページ数・方向・形式・ETag）。
        // direction は実効方向（本ごと override があればその値、なければ config.defaultPageDirection）を
        // 常に返す。null を返さないことで Web リーダーがアプリ設定と同じ既定方向で開く（4.1c）。
        api.get("libraries/:lib/books/:id/manifest") { [config] request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            let content = try BookContentFactory.make(for: row)
            let pageCount = try await content.pageCount
            return ManifestDTO(
                pageCount: pageCount,
                direction: directionString(row.pageDirection ?? config.defaultPageDirection),
                format: formatString(BookCategory.classify(path: row.path ?? "")),
                etag: bookETag(for: row)
            )
        }
        // ページ画像（ハンドルキャッシュ経由・ETag + immutable）。
        // 範囲外 → 404 / 範囲内の描画失敗 → 500（BookContentError.renderFailed 分離・4.1a）。
        // ?maxw= が指定された場合は ETag に幅を織り込み、縮小バイトを返す（4.1c）。
        let contentCache = self.contentCache
        api.get("libraries/:lib/books/:id/pages/:n") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let n = try context.parameters.require("n", as: Int.self)
            let content = try await contentCache.content(for: row, libraryUUID: lib.uuid)
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            let etag = maxwETag(bookETag(for: row) + "-p\(n)", maxw: maxw)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            do {
                var data = try await content.imageData(at: n)
                if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
                return cacheableImageResponse(data: data, etag: etag, request: request)
            } catch let e as BookContentError {
                switch e {
                case .pageOutOfRange: throw HTTPError(.notFound)
                case .renderFailed: throw HTTPError(.internalServerError)
                default: throw HTTPError(.notFound)
                }
            }
        }
        // 閲覧進行状況の書き込み（last_page）＋ mark-as-read（Mac ビューワとパリティ: unseen=false /
        // play_date=now）。本を mutate するので最後に onBookChanged を発火し Mac UI / 将来のクライアントへ
        // 即時反映させる（4.2a）。viewer フラグ（spread/coverOffset）は触らない。
        api.post("libraries/:lib/books/:id/progress") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: ProgressRequestBody.self, context: context)
            guard body.page >= 0 else { throw HTTPError(.badRequest) }
            try lib.db.updateLastPage(bookID: row.id, lastPage: body.page)
            try lib.db.markAsRead(bookID: row.id, at: Date())
            config.onBookChanged?(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // ページ方向の書き戻し（Web リーダーでの変更を本ごと DB に反映・4.1c F2b）。
        api.post("libraries/:lib/books/:id/direction") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: DirectionRequestBody.self, context: context)
            let dir: PageDirection?
            switch body.direction {
            case "rtl": dir = .rightToLeft
            case "ltr": dir = .leftToRight
            case nil, "": dir = nil
            default: throw HTTPError(.badRequest)
            }
            try lib.db.updatePageDirection(bookID: row.id, direction: dir)
            config.onBookChanged?(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 4.2c-9: レート更新（role 不問＝R でも可・共有評価）。0–5 検証。本を mutate するので onBookChanged。
        api.post("libraries/:lib/books/:id/rating") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: RatingRequestBody.self, context: context)
            guard (0...5).contains(body.rating) else { throw HTTPError(.badRequest) }
            try lib.db.setRating(bookID: row.id, rating: body.rating)
            config.onBookChanged?(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 4.2c-9: 未読(unseen)更新（role 不問＝R でも可・共有閲覧状態）。
        api.post("libraries/:lib/books/:id/unseen") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: UnseenRequestBody.self, context: context)
            var patch = BookPatch()
            patch.unseen = body.unseen
            try lib.db.updateBook(id: row.id, patch: patch)
            config.onBookChanged?(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 原本ファイルの一括ダウンロード（4.2 オフライン機能の土台・ストリーミングは YAGNI）。
        api.get("libraries/:lib/books/:id/file") { request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            guard let path = row.path, FileManager.default.fileExists(atPath: path) else {
                throw HTTPError(.notFound)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.eTag] = bookETag(for: row)
            return Response(
                status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
        // 静的 Web クライアント配信（認証不要 — ペアリング前にアプリ本体を読み込むため）。
        // FileMiddleware はルート未一致（.notFound）時のフォールバックとして働く: ルータ直登録
        // すると buildResponder() 時に NotFoundResponder をラップするため、/api/v1 配下の
        // 既存ルートは各自の stack（BearerAuthMiddleware 等）で処理され FileMiddleware に到達しない
        // （= API 認証はそのまま維持）。/ や /app.js のような未一致パスのみ静的ファイルを返す。
        // ★ルート登録規約: /api/v1 配下の新ルートは必ず `api` group（BearerAuthMiddleware 配下）に
        //   登録すること。router 直登録は無警告の認証バイパスになる（4.1a 最終レビュー指摘(3)）。
        // ★book を mutate する API は DB 書き込み成功後に config.onBookChanged?(lib.uuid, row.id) を
        //   呼ぶこと（リモート変更を Mac UI / 将来のクライアントへ即時反映するため・4.2a）。
        if let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)?.path {
            // Web シェル（html/js/css）は `Cache-Control: no-cache` で毎回再検証させる
            // （ETag で 304/200）。これが無いとブラウザのヒューリスティックキャッシュにより
            // アプリ更新後も古い JS が使われ続け、変更が反映されない（4.2c smoke で顕在化）。
            // 表紙/ページ画像は別ルートで immutable 長期キャッシュ（?v= 版管理）のため影響なし。
            router.add(middleware: FileMiddleware(
                webRoot,
                cacheControl: .init([(MediaType(type: .any), [.noCache])]),
                searchForIndexHtml: true))
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname(config.host, port: config.port))
        )
    }

    /// 4.2c-6b: 選択ページから Thumbnails/<id>/thumbnail.jpg を再生成する（App の CoverRefresher 相当）。
    /// preferredName=nil は自動先頭ページ。非対応/失敗は throws（呼び出し側で 500）。
    static func regenerateThumbnail(bookID: Int, sourceURLPath: String?, preferredName: String?, bundleURL: URL) async throws {
        guard let path = sourceURLPath, let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) else {
            throw HTTPError(.internalServerError)
        }
        let data = try await ex.extractCoverImage(from: URL(fileURLWithPath: path), preferredName: preferredName)
        let resized = CoverImageResizer.resizeJPEG(data, maxPixelSize: 1200)
        let url = coverURL(bundleURL: bundleURL, bookID: bookID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try resized.write(to: url)
    }
}

/// unlock リクエストボディ。
struct UnlockRequestBody: Decodable {
    let password: String
}

/// progress 書き込みリクエストボディ（ファイルスコープ — swiftc ASTMangler 対策）。
struct ProgressRequestBody: Decodable {
    let page: Int
}

/// 方向書き込みボディ（swiftc ASTMangler 対策でファイルスコープ）。
struct DirectionRequestBody: Decodable {
    let direction: String?
}

/// 4.2c-9: レート更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有評価）。
struct RatingRequestBody: Decodable {
    let rating: Int
}

/// 4.2c-9: 未読(unseen)更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有閲覧状態）。
struct UnseenRequestBody: Decodable {
    let unseen: Bool
}

/// ?filter=<URL-decoded JSON> から FilterState をデコードする。
/// 不正 JSON / nil は空の FilterState にフォールバックする（呼び出し側で 400 にしない）。
private func decodeFilterState(from jsonString: String?) -> FilterState {
    guard let s = jsonString, !s.isEmpty,
          let data = s.data(using: .utf8),
          let fs = try? JSONDecoder().decode(FilterState.self, from: data)
    else { return FilterState() }
    return fs
}

/// ?browse=<URL-decoded JSON [{"column":…,"value":…}]> から [(String,String)] をデコードする。
/// クライアントは [BrowseConstraint] (オブジェクト配列) として送信する。
/// 不正 JSON / nil は空配列にフォールバックする（バリデーションなし版・内部利用）。
private func decodeBrowseConstraints(from jsonString: String?) -> [(String, String)] {
    guard let s = jsonString, !s.isEmpty,
          let data = s.data(using: .utf8),
          let arr = try? JSONDecoder().decode([BrowseConstraint].self, from: data)
    else { return [] }
    return arr.map { ($0.column, $0.value) }
}

/// ?browse=<URL-decoded JSON [{"column":…,"value":…}]> から [(String,String)] をデコードし、
/// 列名が許可リスト外なら HTTPError(.badRequest) を投げる（SQL injection 防御・4.2b-1b-2b）。
private func decodeBrowseConstraintsValidated(from jsonString: String?) throws -> [(String, String)] {
    let pairs = decodeBrowseConstraints(from: jsonString)
    for (column, _) in pairs {
        guard allowedFacetColumns.contains(column) else { throw HTTPError(.badRequest) }
    }
    return pairs
}

/// ?scope=<scope>&scopeId=<Int64>&recentDays=<Int> から SidebarScope をデコードする。
/// 不正値・未知の scope は .library にフォールバックする（呼び出し側で 400 にしない）。
private func decodeSidebarScope(scope: String?, scopeId: Int64?, recentDays: Int?) -> SidebarScope {
    switch scope {
    case "favorites":
        return scopeId.map { SidebarScope.favorites(playlistID: $0) } ?? .library
    case "recent":
        return .recent(days: recentDays ?? 7)
    case "shelf":
        return scopeId.map { SidebarScope.shelf(playlistID: $0) } ?? .library
    case "smartShelf":
        return scopeId.map { SidebarScope.smartShelf(playlistID: $0) } ?? .library
    default:
        return .library
    }
}

