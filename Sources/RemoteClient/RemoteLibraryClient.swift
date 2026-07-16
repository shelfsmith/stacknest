// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI
import LibraryStore

/// 別 StackNest サーバの HTTP API を叩くクライアント（メタ=JSON 共有 DTO / バイナリ=Data）。
public struct RemoteLibraryClient: Sendable {
    public let baseURL: URL
    public let deviceToken: String
    private let session: URLSession

    public init(baseURL: URL, deviceToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        self.session = session
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1").appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// 非 SSE リクエストの既定アイドルタイムアウト（秒）。既定 60s だと、サーバ不達時に
    /// runLiveSync の reload が最長 60s ハングし、サーバ復帰後もそのリクエストが返るまで再接続を
    /// 試せず赤字復帰が ~40s まで遅れる。10s に短縮（アイドルベース＝データ到着でリセットされるため
    /// 大容量 DL/UP は安全）。ただしサーバ側処理が長く応答バイトが 10s 以上来ないエンドポイント
    /// （重複スキャン等）は呼び出し側で長い timeout を渡す。
    static let defaultRequestTimeout: TimeInterval = 10

    private func request(_ url: URL, method: String = "GET", libraryToken: String? = nil,
                         body: Data? = nil, contentType: String? = nil,
                         cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
                         timeout: TimeInterval = RemoteLibraryClient.defaultRequestTimeout) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: cachePolicy)
        // SSE(events) は本ビルダの後に自前で timeoutInterval=12 に上書きするため影響しない。
        req.timeoutInterval = timeout
        req.httpMethod = method
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let libraryToken { req.setValue(libraryToken, forHTTPHeaderField: "X-Library-Token") }
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RemoteClientError.badResponse }
            switch http.statusCode {
            case 200...299: return data
            case 400: throw RemoteClientError.badRequest(Self.errorMessage(from: data))
            case 401: throw RemoteClientError.unauthorized
            case 403: throw RemoteClientError.forbidden
            case 404: throw RemoteClientError.notFound
            default: throw RemoteClientError.server(http.statusCode)
            }
        } catch let e as RemoteClientError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw RemoteClientError.timeout
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                throw RemoteClientError.offline
            default: throw RemoteClientError.server(-1)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder().decode(T.self, from: data) }
        catch { throw RemoteClientError.decoding }
    }

    /// 400 応答の body からユーザー提示用のエラー文言を取り出す（防御的パース）。
    /// Hummingbird の `HTTPError(_, message:)` は `{"error":{"message":"..."}}` を返すのでそれを優先、
    /// 取れなければ生文字列（短ければ）を使う。何も取れなければ nil。
    private static func errorMessage(from data: Data) -> String? {
        struct HBError: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        if let parsed = try? JSONDecoder().decode(HBError.self, from: data),
           let msg = parsed.error?.message, !msg.isEmpty {
            return msg
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON 断片や巨大 body は避け、短い平文のみ採用。
        if !raw.isEmpty, !raw.hasPrefix("{"), !raw.hasPrefix("["), raw.count <= 300 { return raw }
        return nil
    }

    // MARK: - API

    public func serverInfo() async throws -> ServerCapabilities {
        let data = try await send(request(baseURL.appendingPathComponent("api/v1/server/info")))
        return try decode(ServerCapabilities.self, data)
    }

    public func listLibraries() async throws -> [LibraryDTO] {
        try decode([LibraryDTO].self, try await send(request(makeURL("libraries"))))
    }

    public func unlock(libraryUUID: String, password: String) async throws -> String {
        let body = try JSONEncoder().encode(["password": password])
        let url = makeURL("libraries/\(libraryUUID)/unlock")
        let data = try await send(request(url, method: "POST", body: body, contentType: "application/json"))
        return try decode(UnlockReply.self, data).libraryToken
    }

    private func encodeJSONParam<T: Encodable>(_ v: T) -> String? {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func browseQueryItems(scope: String?, scopeId: Int64?, recentDays: Int?,
                                  filter: FilterState?, browse: [BrowseConstraint]?, q: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
        if let scope { items.append(.init(name: "scope", value: scope)) }
        if let scopeId { items.append(.init(name: "scopeId", value: String(scopeId))) }
        if let recentDays { items.append(.init(name: "recentDays", value: String(recentDays))) }
        if let filter, let j = encodeJSONParam(filter) { items.append(.init(name: "filter", value: j)) }
        if let browse, !browse.isEmpty, let j = encodeJSONParam(browse) { items.append(.init(name: "browse", value: j)) }
        return items
    }

    /// `&fields=` 用クエリ要素。集合は決定的順序にするためソートして連結。空なら nil。
    static func fieldsQueryItem(_ fields: Set<String>) -> URLQueryItem? {
        guard !fields.isEmpty else { return nil }
        return URLQueryItem(name: "fields", value: fields.sorted().joined(separator: ","))
    }

    public func fetchBooks(libraryUUID: String, query: String?, sort: String, ascending: Bool,
                           page: Int, per: Int, libraryToken: String?,
                           scope: String? = nil, scopeId: Int64? = nil, recentDays: Int? = nil,
                           filter: FilterState? = nil, browse: [BrowseConstraint]? = nil,
                           fields: Set<String> = []) async throws -> BookPageDTO {
        var q: [URLQueryItem] = [
            .init(name: "sort", value: sort),
            .init(name: "order", value: ascending ? "asc" : "desc"),
            .init(name: "page", value: String(page)),
            .init(name: "per", value: String(per)),
        ]
        q += browseQueryItems(scope: scope, scopeId: scopeId, recentDays: recentDays, filter: filter, browse: browse, q: query)
        if let f = Self.fieldsQueryItem(fields) { q.append(f) }
        let url = makeURL("libraries/\(libraryUUID)/books", query: q)
        return try decode(BookPageDTO.self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func listShelves(libraryUUID: String, libraryToken: String?) async throws -> [ShelfDTO] {
        let url = makeURL("libraries/\(libraryUUID)/shelves")
        return try decode([ShelfDTO].self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func facetValues(libraryUUID: String, field: String, scope: String?, scopeId: Int64?,
                            recentDays: Int?, filter: FilterState?, browse: [BrowseConstraint]?,
                            q: String?, libraryToken: String?) async throws -> [String] {
        let url = makeURL("libraries/\(libraryUUID)/facets/\(field)",
                          query: browseQueryItems(scope: scope, scopeId: scopeId, recentDays: recentDays, filter: filter, browse: browse, q: q))
        return try decode([String].self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func bookDetail(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> BookDetailDTO {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/detail")
        return try decode(BookDetailDTO.self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func manifest(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> ManifestDTO {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/manifest")
        return try decode(ManifestDTO.self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func pageData(libraryUUID: String, bookID: Int, index: Int, maxw: Int?, libraryToken: String?) async throws -> Data {
        var q: [URLQueryItem] = []
        if let maxw, maxw > 0 { q.append(.init(name: "maxw", value: String(maxw))) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/pages/\(index)", query: q)
        return try await send(request(url, libraryToken: libraryToken))
    }

    public func bookFile(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> Data {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/file")
        // サーバは全ファイルをメモリに読んでから応答するため、大容量アーカイブ×低速ストレージでは
        // 最初のバイトまで 10s を超え得る。既定の短いタイムアウトではなく長め（120s）を渡す。
        return try await send(request(url, libraryToken: libraryToken, timeout: 120))
    }

    /// 受信/総バイトから進捗を算出。総量不明(<=0)は nil。
    static func downloadFraction(received: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, Double(received) / Double(total)))
    }

    /// 進捗通知つき本ファイル取得。onProgress は 0...1（総量不明時は最後に 1.0 のみ）。
    /// shouldCancel: 非 nil の場合、受信中に true を返すと即座に CancellationError で中断する
    /// （ダウンロードの即時キャンセル用。バイトストリームは MainActor 外で回るため、呼び出し側は
    /// スレッド安全なトークンを渡すこと。Task.isCancelled には依存しない）。
    public func bookFile(libraryUUID: String, bookID: Int, libraryToken: String?,
                         onProgress: (@Sendable (Double) -> Void)?,
                         shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> Data {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/file")
        // サーバは全ファイルをメモリに読んでから応答するため最初のバイトまで 10s を超え得る（上の非進捗版と同様）。
        let req = request(url, libraryToken: libraryToken, timeout: 120)
        let (bytes, response) = try await session.bytes(for: req)
        // URLSession は 4xx/5xx で throw しない。ステータスを検証しないとエラー本文を
        // そのままファイルとして保存してしまうため、send(_:) と同じ判定をストリーム消費前に行う。
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401: throw RemoteClientError.unauthorized
            case 403: throw RemoteClientError.forbidden
            case 404: throw RemoteClientError.notFound
            default: throw RemoteClientError.server(http.statusCode)
            }
        } else {
            throw RemoteClientError.badResponse
        }
        let total = response.expectedContentLength   // 不明は -1
        var data = Data()
        if total > 0 { data.reserveCapacity(Int(total)) }
        var received: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            received += 1
            if received % 65536 == 0 {
                // 即時キャンセル: トークンが立っていれば受信を打ち切る（in-flight 中断）。
                if shouldCancel?() == true { throw CancellationError() }
                if let f = Self.downloadFraction(received: received, total: total) {
                    onProgress?(f)
                }
            }
        }
        onProgress?(1.0)
        return data
    }

    public func coverData(libraryUUID: String, bookID: Int, maxw: Int?, libraryToken: String?) async throws -> Data {
        var q: [URLQueryItem] = []
        if let maxw, maxw > 0 { q.append(.init(name: "maxw", value: String(maxw))) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover", query: q)
        // 表紙は差し替わり得るが GET cover は `immutable` 長期キャッシュのため、共有 URLCache が
        // 古い表紙を返し続ける（ライブラリ開き直しまで stale）。L1/L2 が前段にあり URLSession 到達＝
        // キャッシュミス＝新バイトが欲しい時なので、URLCache をバイパスして常に再取得する（G4b stale 修正）。
        return try await send(request(url, libraryToken: libraryToken, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    public func postProgress(libraryUUID: String, bookID: Int, page: Int, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(["page": page])
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/progress")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// 4.2c-9: レート更新（role 不問＝R でも可・共有評価）。
    public func setRating(libraryUUID: String, bookID: Int, rating: Int, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(["rating": rating])
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/rating")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// 4.2c-9: 未読(unseen)更新（role 不問＝R でも可・共有閲覧状態）。
    public func setUnseen(libraryUUID: String, bookID: Int, unseen: Bool, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(["unseen": unseen])
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/unseen")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// 読む方向をサーバへ POST する（/direction は R トークンでも許可）。
    /// direction: "rtl" / "ltr" / nil（クリア）。
    public func updatePageDirection(libraryUUID: String, bookID: Int, direction: String?, libraryToken: String?) async throws {
        struct DirectionBody: Encodable { let direction: String? }
        let body = try JSONEncoder().encode(DirectionBody(direction: direction))
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/direction")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// 同一シリーズの隣接巻メタ。該当なしは nil。direction は "next"/"prev"。
    public func adjacentVolume(libraryUUID: String, bookID: Int, direction: String,
                               libraryToken: String?) async throws -> BookListItemDTO? {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/adjacent",
                          query: [URLQueryItem(name: "dir", value: direction)])
        let data = try await send(request(url, libraryToken: libraryToken))
        return try decode(AdjacentVolumeReply.self, data).book
    }

    /// GET /api/v1/me — 提示トークンの権限情報（role/tier/scope）を返す。
    public func me(libraryToken: String?) async throws -> MeReply {
        let data = try await send(request(makeURL("me"), libraryToken: libraryToken))
        return try decode(MeReply.self, data)
    }

    /// DELETE /api/v1/libraries/:lib/books/:id — 本を削除（admin）。
    /// trash=true で実ファイルを macOS ゴミ箱へ＋DB 削除、false で DB エントリのみ削除（ファイルは残す）。
    public func deleteBook(libraryUUID: String, bookID: Int, trash: Bool, libraryToken: String?) async throws {
        let q = trash ? [URLQueryItem(name: "trash", value: "1")] : []
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)", query: q)
        _ = try await send(request(url, method: "DELETE", libraryToken: libraryToken))
    }

    /// PATCH /api/v1/libraries/:lib/books/:id — メタデータを部分更新し、更新後の BookDetailDTO を返す。
    public func updateBook(libraryUUID: String, bookID: Int, patch: BookPatchDTO,
                           libraryToken: String?) async throws -> BookDetailDTO {
        let body = try JSONEncoder().encode(patch)
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)")
        let data = try await send(request(url, method: "PATCH", libraryToken: libraryToken,
                                          body: body, contentType: "application/json"))
        return try decode(BookDetailDTO.self, data)
    }

    // MARK: - 4.2c-6a: スタンプ定義同期＋一括スタンプ適用

    /// GET /stamp-definitions — スタンプ定義マップ（dbColumn→値配列）。
    public func fetchStampDefinitions(libraryUUID: String, libraryToken: String?) async throws -> [String: [String]] {
        let url = makeURL("libraries/\(libraryUUID)/stamp-definitions")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        return try decode(StampDefinitionsDTO.self, data).definitions
    }

    /// PUT /stamp-definitions — マップ全体を置換し、保存後マップを返す（RW）。
    @discardableResult
    public func putStampDefinitions(_ defs: [String: [String]], libraryUUID: String,
                                    libraryToken: String?) async throws -> [String: [String]] {
        let body = try JSONEncoder().encode(StampDefinitionsDTO(definitions: defs))
        let url = makeURL("libraries/\(libraryUUID)/stamp-definitions")
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken,
                                          body: body, contentType: "application/json"))
        return try decode(StampDefinitionsDTO.self, data).definitions
    }

    /// POST /books/stamp — 一括スタンプ適用（append）/ clear（RW）。更新件数を返す。
    @discardableResult
    public func applyStamp(libraryUUID: String, field: String, value: String?, clear: Bool,
                           bookIDs: [Int], libraryToken: String?) async throws -> Int {
        let body = try JSONEncoder().encode(
            StampApplyRequest(field: field, value: value, clear: clear, bookIDs: bookIDs))
        let url = makeURL("libraries/\(libraryUUID)/books/stamp")
        // 一括適用はサーバ側で N 件更新するため応答まで 10s を超え得る。長め（60s）を渡す。
        let data = try await send(request(url, method: "POST", libraryToken: libraryToken,
                                          body: body, contentType: "application/json", timeout: 60))
        return try decode(StampApplyReply.self, data).updated
    }

    // MARK: - 4.2c-6b: リモート表紙/クロップ編集

    /// GET cover-candidates — ページ名一覧＋現 coverImageName。
    public func fetchCoverCandidates(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> (entries: [String], current: String?) {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover-candidates")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        let dto = try decode(CoverCandidatesDTO.self, data)
        return (dto.entries, dto.current)
    }

    /// GET entry-image — 選択ページ画像（クロップ編集プレビュー）。
    public func fetchEntryImage(libraryUUID: String, bookID: Int, name: String, maxw: Int?, libraryToken: String?) async throws -> Data {
        var q = [URLQueryItem(name: "name", value: name)]
        if let maxw { q.append(URLQueryItem(name: "maxw", value: String(maxw))) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/entry-image", query: q)
        return try await send(request(url, method: "GET", libraryToken: libraryToken))
    }

    /// PUT cover — coverImageName/coverCropRect 更新（更新後 BookDetailDTO）。
    @discardableResult
    public func setRemoteCover(libraryUUID: String, bookID: Int, coverImageName: String?, setName: Bool,
                               coverCropRectJSON: String?, setCrop: Bool, libraryToken: String?) async throws -> BookDetailDTO {
        let body = try JSONEncoder().encode(CoverUpdateRequest(
            coverImageName: coverImageName, setCoverImageName: setName,
            coverCropRect: coverCropRectJSON, setCoverCropRect: setCrop))
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover")
        // ページ変更時サーバが archive からページ抽出＋サムネ再生成してから応答する（cover-image と同類）。
        // 10s を超え得るため長め（30s）を渡す。
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken,
                                          body: body, contentType: "application/json", timeout: 30))
        return try decode(BookDetailDTO.self, data)
    }

    /// G4b: 外部画像を表紙にアップロード（RW）。画像バイトを PUT し、更新後 DTO を返す。
    @discardableResult
    public func setCoverImage(libraryUUID: String, bookID: Int, imageData: Data,
                              cropJSON: String?, libraryToken: String?) async throws -> BookDetailDTO {
        var q: [URLQueryItem] = []
        if let cropJSON { q.append(URLQueryItem(name: "crop", value: cropJSON)) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover-image", query: q)
        // アップロード後にサーバがクロップ＋サムネ再生成してから応答するため 10s を超え得る。長め（30s）を渡す。
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken,
                                          body: imageData, contentType: "image/jpeg", timeout: 30))
        return try decode(BookDetailDTO.self, data)
    }

    /// 4.2c-8: GET label-settings — ラベルカスタマイズ取得（表示用・R 可）。
    public func fetchLabelSettings(libraryUUID: String, libraryToken: String?) async throws -> LabelSettingsDTO {
        let url = makeURL("libraries/\(libraryUUID)/label-settings")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        return try decode(LabelSettingsDTO.self, data)
    }

    /// 4.2c-8: PUT label-settings — ラベルカスタマイズ保存（RW）。保存後の DTO を返す。
    @discardableResult
    public func putLabelSettings(libraryUUID: String,
                                 customFieldLabels: [String: String],
                                 customBookTypeLabels: [String: String],
                                 libraryToken: String?) async throws -> LabelSettingsDTO {
        let body = try JSONEncoder().encode(LabelSettingsDTO(
            customFieldLabels: customFieldLabels, customBookTypeLabels: customBookTypeLabels))
        let url = makeURL("libraries/\(libraryUUID)/label-settings")
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken,
                                          body: body, contentType: "application/json"))
        return try decode(LabelSettingsDTO.self, data)
    }

    // MARK: - G12b-2: 取り込み設定 / ロック / シェルフ membership / 重複スキャン

    /// GET import-config — per-library 取り込み設定（未設定フィールドは nil=グローバル既定に委譲）。
    public func getImportConfig(libraryUUID: String, libraryToken: String?) async throws -> ImportConfigDTO {
        let url = makeURL("libraries/\(libraryUUID)/import-config")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        return try decode(ImportConfigDTO.self, data)
    }

    /// PUT import-config — per-library 取り込み設定を保存し、保存後の DTO を返す（RW）。
    @discardableResult
    public func putImportConfig(_ dto: ImportConfigDTO, libraryUUID: String, libraryToken: String?) async throws -> ImportConfigDTO {
        let body = try JSONEncoder().encode(dto)
        let url = makeURL("libraries/\(libraryUUID)/import-config")
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken, body: body, contentType: "application/json"))
        return try decode(ImportConfigDTO.self, data)
    }

    /// POST lock — ライブラリにパスワードロックを設定する（RW/admin）。
    public func setLock(password: String, libraryUUID: String, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(LockRequest(password: password))
        let url = makeURL("libraries/\(libraryUUID)/lock")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// DELETE lock — ライブラリのパスワードロックを解除する（RW/admin）。
    public func clearLock(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/lock")
        _ = try await send(request(url, method: "DELETE", libraryToken: libraryToken))
    }

    /// POST shelves/:id/books — 手動棚へ本を追加する（RW）。
    public func addBooksToShelf(shelfID: Int64, bookIDs: [Int], libraryUUID: String, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(ShelfBooksRequest(bookIDs: bookIDs))
        let url = makeURL("libraries/\(libraryUUID)/shelves/\(shelfID)/books")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// DELETE shelves/:id/books — 手動棚から本を除去する（RW）。サーバは DELETE でも body(JSON) を読む
    /// ため（`Sources/LibraryServer/LibraryServerCore.swift:377` 付近の `request.decode` 参照）、
    /// URLRequest に httpBody を積んで送る（`request(...)` は method 不問で body を許容する）。
    public func removeBooksFromShelf(shelfID: Int64, bookIDs: [Int], libraryUUID: String, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(ShelfBooksRequest(bookIDs: bookIDs))
        let url = makeURL("libraries/\(libraryUUID)/shelves/\(shelfID)/books")
        _ = try await send(request(url, method: "DELETE", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }

    /// POST duplicates/scan — 重複候補スキャンを実行し、exact/possible グループ＋統計を返す（RW/admin）。
    public func scanDuplicates(libraryUUID: String, libraryToken: String?) async throws -> DuplicateScanReply {
        let url = makeURL("libraries/\(libraryUUID)/duplicates/scan")
        // 大規模ライブラリではサーバ側のハッシュ計算で最初の応答バイトまで 10s を超え得るため、
        // 既定の短いタイムアウトではなく長め（120s）を渡して誤タイムアウトを避ける。
        let data = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 120))
        return try decode(DuplicateScanReply.self, data)
    }

    // MARK: - G14: サイドバー件数

    /// GET counts — サイドバー用のライブラリ総数/直近件数（R 可）。
    public func fetchCounts(libraryUUID: String, libraryToken: String?) async throws -> LibraryCountsDTO {
        let url = makeURL("libraries/\(libraryUUID)/counts")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        return try decode(LibraryCountsDTO.self, data)
    }

    // MARK: - G12b-3a: 一般設定・保守・scan-now

    public func fetchGeneralSettings(libraryUUID: String, libraryToken: String?) async throws -> GeneralSettingsDTO {
        let url = makeURL("libraries/\(libraryUUID)/general-settings")
        return try decode(GeneralSettingsDTO.self, try await send(request(url, method: "GET", libraryToken: libraryToken)))
    }
    @discardableResult
    public func putGeneralSettings(_ dto: GeneralSettingsDTO, libraryUUID: String, libraryToken: String?) async throws -> GeneralSettingsDTO {
        let url = makeURL("libraries/\(libraryUUID)/general-settings")
        let body = try JSONEncoder().encode(dto)
        return try decode(GeneralSettingsDTO.self, try await send(request(url, method: "PUT", libraryToken: libraryToken, body: body, contentType: "application/json", timeout: 30)))
    }
    public func checkIntegrity(libraryUUID: String, libraryToken: String?) async throws -> IntegrityCheckDTO {
        let url = makeURL("libraries/\(libraryUUID)/integrity-check")
        return try decode(IntegrityCheckDTO.self, try await send(request(url, method: "GET", libraryToken: libraryToken, timeout: 60)))
    }
    public func backupNow(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/backup-now")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 120))
    }
    public func scanWatchedFoldersNow(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/watch/scan-now")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 30))
    }
    /// G12b-3c: 指定フォルダの baseline をクリアして既存ファイルも再取込みする（admin）。
    public func importExistingInWatchedFolder(folderID: String, libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/watch/import-existing")
        let body = try JSONEncoder().encode(ImportExistingRequest(folderID: folderID))
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json", timeout: 30))
    }

    // MARK: - G12b-3b: メンテナンス（メタ補完/表紙圧縮・非同期ジョブ）

    /// POST maintenance/complete-metadata — メタ補完ジョブを起動する（admin）。
    /// 202=起動受理（ジョブは非同期、進捗は SSE）。409=他ジョブ実行中で `RemoteClientError.server(409)` を投げる
    /// （呼び出し側 state で 409 を「実行中」表示に使う。追加 case は設けない＝YAGNI）。
    public func startCompleteMetadata(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/maintenance/complete-metadata")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 30))
    }

    /// POST maintenance/compress-covers — 表紙圧縮ジョブを起動する（admin）。202/409 は上記と同様。
    public func startCompressCovers(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/maintenance/compress-covers")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 30))
    }

    /// POST maintenance/cancel — 実行中のメンテナンスジョブをキャンセルする（admin）。
    public func cancelMaintenance(libraryUUID: String, libraryToken: String?) async throws {
        let url = makeURL("libraries/\(libraryUUID)/maintenance/cancel")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 30))
    }

    // MARK: - G12b-2c: 監視フォルダ設定

    /// GET watch-config — 監視フォルダ設定＋プリセット一覧（R 可）。
    public func fetchWatchConfig(libraryUUID: String, libraryToken: String?) async throws -> WatchConfigDTO {
        let url = makeURL("libraries/\(libraryUUID)/watch-config")
        let data = try await send(request(url, method: "GET", libraryToken: libraryToken))
        return try decode(WatchConfigDTO.self, data)
    }

    /// PUT watch-config — 監視フォルダ設定を保存し、適用後の設定を返す（RW）。
    /// baseline スキャン（新規フォルダ追加）でサーバ処理が伸びうるため長め（30s）。
    @discardableResult
    public func putWatchConfig(_ dto: WatchConfigDTO, libraryUUID: String, libraryToken: String?) async throws -> WatchConfigDTO {
        let url = makeURL("libraries/\(libraryUUID)/watch-config")
        let body = try JSONEncoder().encode(dto)
        let data = try await send(request(url, method: "PUT", libraryToken: libraryToken,
                                          body: body, contentType: "application/json", timeout: 30))
        return try decode(WatchConfigDTO.self, data)
    }

    // MARK: - G12b-3c: 命名プリセット

    /// GET presets — ファイル名フォーマットのプリセット一覧＋既定 ID（R 可）。
    public func fetchPresets(libraryUUID: String, libraryToken: String?) async throws -> PresetSetDTO {
        let url = makeURL("libraries/\(libraryUUID)/presets")
        return try decode(PresetSetDTO.self, try await send(request(url, method: "GET", libraryToken: libraryToken)))
    }

    /// PUT presets — プリセット一覧＋既定 ID を保存し、保存後の DTO を返す（RW）。
    @discardableResult
    public func putPresets(_ dto: PresetSetDTO, libraryUUID: String, libraryToken: String?) async throws -> PresetSetDTO {
        let url = makeURL("libraries/\(libraryUUID)/presets")
        let body = try JSONEncoder().encode(dto)
        return try decode(PresetSetDTO.self, try await send(request(url, method: "PUT", libraryToken: libraryToken, body: body, contentType: "application/json", timeout: 30)))
    }

    // MARK: - G8a: ライブ同期（SSE）

    /// G8a: ライブ同期イベントを購読する（SSE・Design 1）。
    /// 正常クローズ＝throw なし finish、非200/URLError＝型付き RemoteClientError で終端 throw。
    public func events(libraryToken: String?) -> AsyncThrowingStream<LiveEvent, Error> {
        let url = makeURL("events")
        let req: URLRequest = {
            var r = request(url, libraryToken: libraryToken)
            r.timeoutInterval = 12                 // G14: 有限アイドルタイムアウト(12s>サーバ5s HB)。生存接続はHBで維持、死んだ/到達不能サーバは~12sで失敗→backoff再接続。無期限だとTailscaleでconnectがOS~60sまでハングし赤字が長期残留する
            return r
        }()
        let session = self.session
        return AsyncThrowingStream<LiveEvent, Error> { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    // status 検証（bookFile と同じ判定）。非200 は型付きで終端 throw。
                    if let http = resp as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200...299: break
                        case 401: continuation.finish(throwing: RemoteClientError.unauthorized); return
                        case 403: continuation.finish(throwing: RemoteClientError.forbidden); return
                        case 404: continuation.finish(throwing: RemoteClientError.notFound); return
                        default: continuation.finish(throwing: RemoteClientError.server(http.statusCode)); return
                        }
                    } else {
                        continuation.finish(throwing: RemoteClientError.badResponse); return
                    }
                    continuation.yield(.connected)   // G13: 接続確立を通知（再接続後の errorText クリア/取りこぼし回収用）
                    // NOTE: URLSession.AsyncBytes.lines は**空行を落とす**が、SSE は空行（"\n\n"）を
                    // フレーム区切りとして使い、SSEParser はそれを見て初めて LiveEvent を emit する。
                    // よって .lines は使わず、生バイトを行末込みで SSEParser へ流す（下記ヘルパ）。
                    try await SSEParser.forEachEvent(inRawBytes: bytes) { continuation.yield($0) }
                    continuation.finish()                    // サーバ正常クローズ（throw なし）
                } catch is CancellationError {
                    continuation.finish()                    // キャンセルは静かに finish
                } catch let e as URLError {
                    // send(_:) と同じ URLError→RemoteClientError 写像。
                    switch e.code {
                    case .cancelled: continuation.finish()   // URLSession.bytes のキャンセルは URLError(.cancelled)。静音 finish（再接続させない）
                    case .timedOut: continuation.finish(throwing: RemoteClientError.timeout)
                    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                        continuation.finish(throwing: RemoteClientError.offline)
                    default: continuation.finish(throwing: RemoteClientError.server(-1))
                    }
                } catch {
                    continuation.finish(throwing: RemoteClientError.server(-1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
