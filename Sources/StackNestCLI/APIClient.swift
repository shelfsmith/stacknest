// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

// MARK: - Error

enum APIError: Error, CustomStringConvertible {
    case notFound
    case http(status: Int)
    case network(Error)
    case decode(Error)

    var description: String {
        switch self {
        case .notFound: return "HTTP 404: リソースが見つかりません"
        case .http(let s): return "HTTP \(s): サーバエラー"
        case .network(let e): return "ネットワークエラー: \(e.localizedDescription)"
        case .decode(let e): return "デコードエラー: \(e.localizedDescription)"
        }
    }
}

// MARK: - Client

/// URLSession 同期ラッパ（DispatchSemaphore）。CLI は短命なので sync で問題ない。
struct APIClient {
    let endpoint: ResolvedEndpoint

    /// /api/v1 プレフィックスを付与した API ベース URL（末尾スラッシュ無し）
    private var apiBase: String { endpoint.baseURL + "/api/v1" }

    var token: String { endpoint.token }

    /// テスト可能な URL 構築ヘルパ。path は先頭スラッシュあり（例: "/libraries"）。
    func makeURL(_ path: String) -> URL {
        URL(string: apiBase + path)!
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    // MARK: - Sync request helpers

    private func request(_ url: URL, method: String = "GET",
                         body: Data? = nil, timeout: TimeInterval? = nil) throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !endpoint.libraryToken.isEmpty {
            req.setValue(endpoint.libraryToken, forHTTPHeaderField: "X-Library-Token")
        }
        if let timeout {
            req.timeoutInterval = timeout
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var result: Result<Data, Error>?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sema.signal() }
            if let error {
                result = .failure(APIError.network(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { result = .failure(APIError.notFound); return }
            if status < 200 || status >= 300 { result = .failure(APIError.http(status: status)); return }
            result = .success(data ?? Data())
        }.resume()
        sema.wait()

        switch result! {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }

    // MARK: - Public API

    /// GET /api/v1/libraries → JSON Data
    func libraries() throws -> Data {
        try request(makeURL("/libraries"))
    }

    /// GET /api/v1/libraries/:uuid/books → JSON Data（BookPageDTO）
    /// limit はサーバの per（1ページ件数・サーバ側で 1...500 にクランプ）。
    /// filterJSON/browseJSON は URL-encoded JSON としてそのまま渡す（サーバが検証）。
    func listBooks(uuid: String, query: String? = nil, limit: Int? = nil,
                   sort: String? = nil, order: String? = nil,
                   scope: String? = nil, scopeId: Int64? = nil, recentDays: Int? = nil,
                   fields: String? = nil, filterJSON: String? = nil, browseJSON: String? = nil) throws -> Data {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        var items: [String] = []
        if let q = query, !q.isEmpty { items.append("q=\(enc(q))") }
        if let limit { items.append("per=\(limit)") }
        if let sort { items.append("sort=\(enc(sort))") }
        if let order { items.append("order=\(enc(order))") }
        if let scope { items.append("scope=\(enc(scope))") }
        if let scopeId { items.append("scopeId=\(scopeId)") }
        if let recentDays { items.append("recentDays=\(recentDays)") }
        if let fields, !fields.isEmpty { items.append("fields=\(enc(fields))") }
        if let filterJSON, !filterJSON.isEmpty { items.append("filter=\(enc(filterJSON))") }
        if let browseJSON, !browseJSON.isEmpty { items.append("browse=\(enc(browseJSON))") }
        let urlStr = apiBase + "/libraries/\(uuid)/books" + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
        return try request(URL(string: urlStr)!)
    }

    /// POST /api/v1/libraries/:uuid/books → AddBooksReplyDTO
    func add(uuid: String, req: AddBooksRequestDTO) throws -> AddBooksReplyDTO {
        let body = try encoder.encode(req)
        let data = try request(makeURL("/libraries/\(uuid)/books"), method: "POST", body: body)
        do {
            return try decoder.decode(AddBooksReplyDTO.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    /// DELETE /api/v1/libraries/:uuid/books/:id
    func remove(uuid: String, id: Int, trash: Bool) throws {
        var urlStr = apiBase + "/libraries/\(uuid)/books/\(id)"
        if trash { urlStr += "?trash=1" }
        _ = try request(URL(string: urlStr)!, method: "DELETE")
    }

    /// PATCH /api/v1/libraries/:uuid/books/:id
    func patch(uuid: String, id: Int, body: BookPatchDTO) throws {
        let data = try encoder.encode(body)
        _ = try request(makeURL("/libraries/\(uuid)/books/\(id)"), method: "PATCH", body: data)
    }

    /// GET /api/v1/libraries/:uuid/books/:id/detail → JSON Data（BookDetailDTO）
    func detail(uuid: String, id: Int) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/books/\(id)/detail"))
    }

    /// GET /api/v1/libraries/:uuid/facets/:field → JSON Data（[String]）
    func facets(uuid: String, field: String) throws -> Data {
        let enc = field.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? field
        return try request(makeURL("/libraries/\(uuid)/facets/\(enc)"))
    }

    /// GET /api/v1/libraries/:uuid/shelves → JSON Data（[ShelfDTO]）
    func shelves(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/shelves"))
    }

    /// GET /api/v1/me → JSON Data（MeReply）
    func me() throws -> Data {
        try request(makeURL("/me"))
    }

    /// POST /api/v1/libraries/:uuid/unlock → JSON Data（UnlockReply）
    /// body は {"password": ...}（LockRequest と同一 wire 形を再利用）。
    func unlock(uuid: String, password: String) throws -> Data {
        let body = try encoder.encode(LockRequest(password: password))
        return try request(makeURL("/libraries/\(uuid)/unlock"), method: "POST", body: body)
    }

    // MARK: - 棚 CRUD

    func shelfCreate(uuid: String, body: ShelfCreateRequest) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/shelves"), method: "POST", body: try encoder.encode(body))
    }
    func shelfDelete(uuid: String, id: Int64) throws {
        _ = try request(makeURL("/libraries/\(uuid)/shelves/\(id)"), method: "DELETE")
    }
    func shelfPatch(uuid: String, id: Int64, body: ShelfUpdateRequest) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/shelves/\(id)"), method: "PATCH", body: try encoder.encode(body))
    }
    func shelfConditionsGet(uuid: String, id: Int64) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/shelves/\(id)/conditions"))
    }
    func shelfConditionsPut(uuid: String, id: Int64, conditionsJSON: Data) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/shelves/\(id)/conditions"), method: "PUT", body: conditionsJSON)
    }
    func shelfBooksAdd(uuid: String, id: Int64, bookIDs: [Int]) throws {
        let body = try encoder.encode(ShelfBooksRequest(bookIDs: bookIDs))
        _ = try request(makeURL("/libraries/\(uuid)/shelves/\(id)/books"), method: "POST", body: body)
    }
    func shelfBooksRemove(uuid: String, id: Int64, bookIDs: [Int]) throws {
        let body = try encoder.encode(ShelfBooksRequest(bookIDs: bookIDs))
        _ = try request(makeURL("/libraries/\(uuid)/shelves/\(id)/books"), method: "DELETE", body: body)
    }

    // MARK: - ライブラリ管理

    func watchGet(uuid: String) throws -> Data { try request(makeURL("/libraries/\(uuid)/watch-config")) }
    func watchPut(uuid: String, configJSON: Data) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/watch-config"), method: "PUT", body: configJSON)
    }
    /// G27a Task6: `currentPassword` は既存ロックの変更時のみ必須（新規設定時は nil で良い）。
    func lockSet(uuid: String, password: String, currentPassword: String? = nil) throws {
        let body = try encoder.encode(LockRequest(password: password, currentPassword: currentPassword))
        _ = try request(makeURL("/libraries/\(uuid)/lock"), method: "POST", body: body)
    }
    /// G27a Task6: `currentPassword` は既存ロックがある場合のみ必須。nil のときはボディ自体を
    /// 送らない（サーバは空ボディを「現パスワード無し」として扱う＝ロックが無い庫への後方互換）。
    func lockClear(uuid: String, currentPassword: String? = nil) throws {
        var body: Data? = nil
        if let currentPassword {
            body = try encoder.encode(LockRemoveRequest(currentPassword: currentPassword))
        }
        _ = try request(makeURL("/libraries/\(uuid)/lock"), method: "DELETE", body: body)
    }
    func importGet(uuid: String) throws -> Data { try request(makeURL("/libraries/\(uuid)/import-config")) }
    func importPut(uuid: String, body: ImportConfigDTO) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/import-config"), method: "PUT", body: try encoder.encode(body))
    }
    func importGlobalGet() throws -> Data { try request(makeURL("/import-config")) }
    func importGlobalPut(body: GlobalImportConfigDTO) throws -> Data {
        try request(makeURL("/import-config"), method: "PUT", body: try encoder.encode(body))
    }
    func relink(uuid: String, id: Int, newPath: String) throws {
        let body = try encoder.encode(RelinkRequest(newPath: newPath))
        _ = try request(makeURL("/libraries/\(uuid)/books/\(id)/relink"), method: "POST", body: body)
    }
    func dedup(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/duplicates/scan"), method: "POST")
    }

    // MARK: - 整合性検査（G27a）

    /// POST /api/v1/libraries/{uuid}/integrity/scan → JSON Data（IntegrityScanReply）
    /// 実測 65 候補 ≈ 4 分（1 冊 ≈ 3.46s）。URLSession.shared の既定 60s では確実にタイムアウトし、
    /// クライアント側が諦めてもサーバ側の走査は続くため、リトライで二重走査が起きる。
    /// この呼び出しだけ長いタイムアウトを与える（他のリクエストの既定は変えない）。
    /// 同期 1 リクエストで待つ形自体は既知の制約 — 非同期ジョブ化＋ポーリングは Phase G27b で検討する。
    func integrityScan(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/integrity/scan"), method: "POST", timeout: 1800)
    }

    /// GET /api/v1/libraries/{uuid}/integrity/summary → JSON Data（IntegritySummaryReply）
    func integritySummary(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/integrity/summary"))
    }

    /// GET /api/v1/libraries/{uuid}/integrity/list?status=… → JSON Data（IntegrityListReply）
    func integrityList(uuid: String, status: String) throws -> Data {
        let enc = status.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? status
        return try request(makeURL("/libraries/\(uuid)/integrity/list?status=\(enc)"))
    }

    // MARK: - フル CRC スキャン（非同期ジョブ・G27b Task5）
    //
    // 実測 4.464 秒/冊・22,880 冊規模で約 31 時間かかる。integrityScan（簡易チェック）と違い
    // 「サーバ側は非同期ジョブとして開始・クライアントは 202 を確認したらすぐ返る」設計にする
    // ―― タイムアウトを延ばして待つやり方はここでは通用しない（確実にタイムアウトする）。

    /// POST /api/v1/libraries/{uuid}/integrity/full-scan {mode} → 202（起動受理）。
    /// 実行中に再度呼ぶとサーバは 409 を返す（`APIError.http(status: 409)` として throw される。
    /// 呼び出し側で明示的にハンドルすること）。
    @discardableResult
    func startFullScan(uuid: String, mode: String) throws -> Data {
        let body = try encoder.encode(FullScanStartRequest(mode: mode))
        return try request(makeURL("/libraries/\(uuid)/integrity/full-scan"), method: "POST", body: body)
    }

    /// GET /api/v1/libraries/{uuid}/maintenance/status → JSON Data（MaintenanceStatusReply）
    /// full-scan に限らず complete-metadata/compress-covers も同じ registry を共有するため、
    /// このエンドポイントは「今その庫で走っているジョブ全般」の状態を返す。
    func maintenanceStatus(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/maintenance/status"))
    }

    /// POST /api/v1/libraries/{uuid}/maintenance/cancel → 204（実行中ジョブが無くても no-op で 204）。
    /// full-scan 専用の中断エンドポイントは無い ―― 既存のこのエンドポイントをそのまま使う。
    func maintenanceCancel(uuid: String) throws {
        _ = try request(makeURL("/libraries/\(uuid)/maintenance/cancel"), method: "POST")
    }

    // MARK: - グラント CRUD（admin）

    /// GET /api/v1/grants → JSON Data（[GrantDTO]）
    func grantList() throws -> Data { try request(makeURL("/grants")) }
    /// POST /api/v1/grants → JSON Data（GrantDTO・token を含む）
    func grantCreate(body: GrantCreateRequest) throws -> Data {
        try request(makeURL("/grants"), method: "POST", body: try encoder.encode(body))
    }
    /// PATCH /api/v1/grants/:id → JSON Data（GrantDTO）
    func grantUpdate(id: String, body: GrantUpdateRequest) throws -> Data {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try request(makeURL("/grants/\(enc)"), method: "PATCH", body: try encoder.encode(body))
    }
    /// DELETE /api/v1/grants/:id
    func grantDelete(id: String) throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try request(makeURL("/grants/\(enc)"), method: "DELETE")
    }

    // MARK: - stamp / label（per-library）

    /// POST /api/v1/libraries/:uuid/books/stamp → JSON Data（StampApplyReply）
    func stampApply(uuid: String, body: StampApplyRequest) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/books/stamp"), method: "POST", body: try encoder.encode(body))
    }
    /// GET /api/v1/libraries/:uuid/stamp-definitions → JSON Data（StampDefinitionsDTO）
    func stampDefinitionsGet(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/stamp-definitions"))
    }
    /// PUT /api/v1/libraries/:uuid/stamp-definitions（body は StampDefinitionsDTO の JSON）
    func stampDefinitionsPut(uuid: String, json: Data) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/stamp-definitions"), method: "PUT", body: json)
    }
    /// GET /api/v1/libraries/:uuid/label-settings → JSON Data（LabelSettingsDTO）
    func labelGet(uuid: String) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/label-settings"))
    }
    /// PUT /api/v1/libraries/:uuid/label-settings（body は LabelSettingsDTO の JSON）
    func labelPut(uuid: String, json: Data) throws -> Data {
        try request(makeURL("/libraries/\(uuid)/label-settings"), method: "PUT", body: json)
    }

    // MARK: - ライブラリ開閉（ローカル制御専用・G27b Task7）
    //
    // /api/v1 配下ではなく /local 配下（apiBase を経由しない）。共有サーバにはこのルート自体が
    // 存在しない（LibraryServerConfig.enableLocalLibraryControl は LocalControlController だけが true）。

    /// POST /local/libraries/open {path} → JSON Data（OpenLibraryReply）
    func openLibrary(path: String) throws -> Data {
        let body = try encoder.encode(OpenLibraryRequest(path: path))
        let url = URL(string: endpoint.baseURL + "/local/libraries/open")!
        return try request(url, method: "POST", body: body)
    }

    /// POST /local/libraries/close {uuid} → 204
    func closeLibrary(uuid: String) throws {
        let body = try encoder.encode(CloseLibraryRequest(uuid: uuid))
        let url = URL(string: endpoint.baseURL + "/local/libraries/close")!
        _ = try request(url, method: "POST", body: body)
    }

    /// G39: GET /local/libraries/:uuid/finder-tags → 同期対象・走行中・施錠中。
    func finderTagStatus(uuid: String) throws -> Data {
        let url = URL(string: endpoint.baseURL + "/local/libraries/\(uuid)/finder-tags")!
        return try request(url)
    }

    /// G39: PUT /local/libraries/:uuid/finder-tags → 同期対象の項目を変える（nil＝同期しない）。
    func finderTagSetField(uuid: String, field: String?) throws -> Data {
        let body = try encoder.encode(FinderTagSyncFieldRequest(field: field))
        let url = URL(string: endpoint.baseURL + "/local/libraries/\(uuid)/finder-tags")!
        return try request(url, method: "PUT", body: body)
    }

    /// G39: POST /local/libraries/:uuid/finder-tags/resync → 同期の結果。
    ///
    /// **同期が終わるまでサーバが応答を返さない。**12,000 冊で実測 0.4 秒だが、
    /// `mdfind` が遅いといくらでも伸びるので、既定より長い待ちを与える。
    func finderTagResync(uuid: String) throws -> Data {
        let url = URL(string: endpoint.baseURL + "/local/libraries/\(uuid)/finder-tags/resync")!
        return try request(url, method: "POST", timeout: 600)
    }
}
