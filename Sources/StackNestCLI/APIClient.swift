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
                         body: Data? = nil) throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !endpoint.libraryToken.isEmpty {
            req.setValue(endpoint.libraryToken, forHTTPHeaderField: "X-Library-Token")
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
    func listBooks(uuid: String, query: String?, limit: Int?) throws -> Data {
        var items: [String] = []
        if let q = query, !q.isEmpty {
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            items.append("q=\(enc)")
        }
        if let limit { items.append("per=\(limit)") }
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
    func lockSet(uuid: String, password: String) throws {
        let body = try encoder.encode(LockRequest(password: password))
        _ = try request(makeURL("/libraries/\(uuid)/lock"), method: "POST", body: body)
    }
    func lockClear(uuid: String) throws { _ = try request(makeURL("/libraries/\(uuid)/lock"), method: "DELETE") }
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
}
