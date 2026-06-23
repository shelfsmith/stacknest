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
    let baseURL: String   // 末尾スラッシュ無し
    let token: String

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

    private func request(_ urlStr: String, method: String = "GET",
                         body: Data? = nil) throws -> Data {
        guard let url = URL(string: urlStr) else {
            throw APIError.network(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    /// GET /libraries → JSON Data
    func libraries() throws -> Data {
        try request("\(baseURL)/libraries")
    }

    /// GET /libraries/:uuid/books → JSON Data（BookPageDTO）
    func listBooks(uuid: String, query: String?) throws -> Data {
        var url = "\(baseURL)/libraries/\(uuid)/books"
        if let q = query, !q.isEmpty {
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            url += "?q=\(enc)"
        }
        return try request(url)
    }

    /// POST /libraries/:uuid/books → AddBooksReplyDTO
    func add(uuid: String, req: AddBooksRequestDTO) throws -> AddBooksReplyDTO {
        let body = try encoder.encode(req)
        let data = try request("\(baseURL)/libraries/\(uuid)/books", method: "POST", body: body)
        do {
            return try decoder.decode(AddBooksReplyDTO.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    /// DELETE /libraries/:uuid/books/:id
    func remove(uuid: String, id: Int, trash: Bool) throws {
        var url = "\(baseURL)/libraries/\(uuid)/books/\(id)"
        if trash { url += "?trash=1" }
        _ = try request(url, method: "DELETE")
    }

    /// PATCH /libraries/:uuid/books/:id
    func patch(uuid: String, id: Int, body: BookPatchDTO) throws {
        let data = try encoder.encode(body)
        _ = try request("\(baseURL)/libraries/\(uuid)/books/\(id)", method: "PATCH", body: data)
    }
}
