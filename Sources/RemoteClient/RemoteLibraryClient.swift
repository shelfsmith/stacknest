// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI
import LibraryStore

/// 別 StackNest サーバの HTTP API を叩くクライアント（メタ=JSON 共有 DTO / バイナリ=Data）。
public struct RemoteLibraryClient: Sendable {
    public let baseURL: URL
    public let deviceToken: String
    private let session: URLSession

    /// #13: 本クライアントは固定 base URL としか通信しないため HTTP リダイレクトは想定されない。
    /// 悪意あるサーバが 3xx で資格情報（Bearer/X-Library-Token）付きリクエストを別ホストへ
    /// 誘導する（SSRF / トークン転送）のを防ぐため、リダイレクトに一切従わないデリゲート。
    final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // リダイレクトを拒否（元応答をそのまま呼び出し元へ返す）
        }
    }

    /// リダイレクト拒否デリゲート付きの既定セッション（#13）。テストは独自 session を注入するため影響なし。
    public static let noRedirectSession: URLSession =
        URLSession(configuration: .default, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)

    public init(baseURL: URL, deviceToken: String, session: URLSession = RemoteLibraryClient.noRedirectSession) {
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
        try await sendWithResponse(req).data
    }

    /// `send(_:)` と同じステータス判定を行うが、応答ヘッダ確認が必要な呼び出し元
    /// （review follow-up Finding 1: `pageData` の `Cache-Control: no-store` 判定）のために
    /// `HTTPURLResponse` も一緒に返す最小限の分岐。`send(_:)` は本メソッドの `data` だけを
    /// 使う薄いラッパに変えてあるため、既存の全呼び出し元の挙動は変わらない。
    private func sendWithResponse(_ req: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        do {
            // G23 (M1) / Codex High #3: **逐次受信**にして上限到達で実際に受信を打ち切る。
            //
            // 当初は `session.data(for:)`（全量読み込み後に検査）だったが、それでは
            // Content-Length を詐称された場合に**受信そのものを止められず**、巨大応答が
            // 一度メモリへ載ってしまう。「受信サイズ上限」という要件を満たしていなかった。
            // ここは JSON / 表紙 / ページ画像がすべて通る単一の集約点なので、この 1 箇所で
            // 汎用経路全体を守れる。
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RemoteClientError.badResponse }
            // 宣言サイズが上限を超えるなら本文を読み始める前に弾く。
            if Self.exceedsGeneralLimit(declaredLength: http.expectedContentLength, receivedCount: 0) {
                throw RemoteClientError.responseTooLarge
            }
            // 1 バイトずつ `Data.append` すると遅いので、チャンクに貯めてからまとめて足す。
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(http.expectedContentLength,
                                             Int64(Self.maxGeneralResponseBytes))))
            }
            var chunk = Data()
            chunk.reserveCapacity(Self.flushChunkBytes)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= Self.flushChunkBytes {
                    data.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    // 詐称された Content-Length はここで止まる（受信を継続しない）。
                    if Self.exceedsGeneralLimit(declaredLength: -1, receivedCount: data.count) {
                        throw RemoteClientError.responseTooLarge
                    }
                }
            }
            if !chunk.isEmpty { data.append(chunk) }
            if Self.exceedsGeneralLimit(declaredLength: -1, receivedCount: data.count) {
                throw RemoteClientError.responseTooLarge
            }
            switch http.statusCode {
            case 200...299:
                return (data, http)
            case 400: throw RemoteClientError.badRequest(Self.errorMessage(from: data))
            case 401: throw RemoteClientError.unauthorized
            case 403: throw RemoteClientError.forbidden(headers: Self.headerMap(http))
            case 404: throw RemoteClientError.notFound
            default: throw RemoteClientError.server(http.statusCode)
            }
        } catch let e as RemoteClientError {
            throw e
        } catch let e as URLError {
            throw Self.classify(e)
        }
    }

    /// URLError → RemoteClientError の純粋な写像（テスト可能な形に切り出し）。
    /// G21 #4: `.cancelled` は「上位の Task キャンセルで in-flight リクエストが打ち切られた」ことを表す
    /// 専用ケースとして分類する。以前は default 分岐に落ちて `server(-1)` に丸められており、
    /// 複数削除で誘発される SSE デバウンス flush の cancel→再実行が liveReload に赤いエラーバナーを
    /// 誤表示させていた（実機ログで確認済み）。他のケースの挙動は変えない。
    static func classify(_ e: URLError) -> RemoteClientError {
        switch e.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return .offline
        default: return .server(-1)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder().decode(T.self, from: data) }
        catch { throw RemoteClientError.decoding }
    }

    /// 400 応答の body からユーザー提示用のエラー文言を取り出す（防御的パース）。
    /// Hummingbird の `HTTPError(_, message:)` は `{"error":{"message":"..."}}` を返すのでそれを優先、
    /// 取れなければ生文字列（短ければ）を使う。何も取れなければ nil。
    /// G25d: 403 の種別判定にヘッダを渡すための抽出。
    static func headerMap(_ http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { out[ks] = vs }
        }
        return out
    }

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

    /// G4d HTTP キャッシュ追随修正: ページ画像は `Cache-Control: immutable` の長期キャッシュ対象
    /// （`cacheableImageResponse`）だが、URL がバージョンレスだと relink 後もその URL の
    /// URLCache エントリが「絶対に変わらない」と誤認され続け、アプリ層のキャッシュキーが
    /// version でミスして再取得しても、そのリクエストが古い immutable エントリで即答されて
    /// 古いバイトを新版キーの下に固定してしまう（本 bug の core）。cover（G4b）と同じ設計で、
    /// version がある時は `?v=` を URL に織り込んで immutable を健全化し（同じ URL の中身は
    /// 本当に変わらない＝未変更版は無料でキャッシュヒットする）、version が無い（manifest 取得
    /// 失敗等のフォールバック）ときだけ URLCache を明示バイパスして「版不明な URL の immutable
    /// エントリを信用しない」を保証する。version は呼び出し元（RemoteBookContent）が
    /// versionValue（normalizeVersion 済み・キャッシュキーと同じ値）をそのまま渡すこと。
    ///
    /// review follow-up Finding 1: 戻り値は `(data, noStore)`（以前は `Data` 単体）。サーバは
    /// リクエストの `?v=` が現在版と食い違うとき、正しい現在バイトを 200 で返しつつ
    /// `Cache-Control: no-store` を立てる（`cacheableImageResponse` 参照）。これは URLCache
    /// （HTTP キャッシュ層）は無効化するが、アプリ層の `RemotePageCache` には自動では及ばない
    /// ため、`noStore` をここで呼び出し元（`RemoteBookContent.imageData`）へ伝播し、
    /// `RemotePageCache` への `store` をスキップさせる（でないと relink 直後に届いた別版の
    /// バイトが旧版キーの下に永続化され、後で relink し戻ったときに stale を返し続ける）。
    public func pageData(libraryUUID: String, bookID: Int, index: Int, maxw: Int?, version: String?,
                        libraryToken: String?) async throws -> (data: Data, noStore: Bool) {
        var q: [URLQueryItem] = []
        if let maxw, maxw > 0 { q.append(.init(name: "maxw", value: String(maxw))) }
        if let version { q.append(.init(name: "v", value: version)) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/pages/\(index)", query: q)
        let policy: URLRequest.CachePolicy = version == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        let (data, response) = try await sendWithResponse(request(url, libraryToken: libraryToken, cachePolicy: policy))
        let noStore = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().contains("no-store")
        return (data, noStore)
    }

    // G23 (M2): 非進捗版 `bookFile(libraryUUID:bookID:libraryToken:) -> Data` は削除した。
    // 本番から使われずテスト専用になっていたうえ、`send(_:)` 経由＝汎用取得経路の受信上限
    // （M1 の 64MiB）が本ファイルにも掛かってしまい、大きな本を取得できなくなるため。
    // 取得は下の進捗つき版（一時ファイルへストリーミング）に一本化する。

    /// 受信/総バイトから進捗を算出。総量不明(<=0)は nil。
    static func downloadFraction(received: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, Double(received) / Double(total)))
    }

    // G23 (M2): `maxReserveCapacityBytes` と `clampedReserveCapacity` は削除した。
    // #12 で導入した「詐称された Content-Length による巨大メモリ確保を防ぐ」対策だが、
    // 唯一の利用箇所だった `bookFile` の `Data.reserveCapacity` がストリーミング化で無くなり、
    // テストからしか参照されないデッドコードになったため。宣言サイズに基づく事前確保を
    // 一切行わなくなったので、この対策自体が不要になっている。

    /// #12: 1 ファイルダウンロードの総受信量上限。`Content-Length` を詐称/省略された上で
    /// 実際に無限に近いバイト列を送り続けるサーバに対する保険（reserveCapacity のクランプだけでは
    /// 実受信ループそのものは止まらない）。既存の正規書庫（zip/cbz/pdf）はこの上限を大きく
    /// 下回るため、通常利用への影響はない。
    /// G23 (M2): 4GiB から引き下げた。一時ファイルへ流すようになりメモリ枯渇の即死性は下がったが、
    /// 上限としては実態（正規の書庫は数百 MB 以下）から乖離しすぎており、ディスクを埋める余地が残るため。
    static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2GiB

    /// 受信済みバイト数が総受信量上限を超えたか（純粋な比較のみ。GiB 単位のダミーデータを
    /// 実際に流さずとも境界値をユニットテストできるよう切り出す）。
    static func exceedsMaxDownloadBytes(received: Int64) -> Bool {
        received > maxDownloadBytes
    }

    /// G23 (M1): JSON / 表紙 / ページ画像など**汎用取得経路**の受信上限。
    /// `maxDownloadBytes`（本ファイル 1 件）とは別枠で、これらは本来いずれも数 MB 以下に収まる。
    /// 上限を分けているのは、汎用経路の方をはるかに小さく保てるため。
    static let maxGeneralResponseBytes = 64 * 1024 * 1024   // 64MiB

    /// 宣言 Content-Length（不明は -1）と実受信量のいずれかが上限を超えたか。
    /// 宣言値は受信前の足切り、実受信量は Content-Length 詐称への保険として使う。
    static func exceedsGeneralLimit(declaredLength: Int64, receivedCount: Int) -> Bool {
        if declaredLength > Int64(maxGeneralResponseBytes) { return true }
        return receivedCount > maxGeneralResponseBytes
    }

    /// 進捗通知つき本ファイル取得。**一時ファイルへ書き出し、その URL を返す**。
    ///
    /// G23 (M2): 以前は `Data` に全量を蓄積していたため、大きな本ほどメモリを圧迫した
    /// （攻撃と無関係に通常利用で顕在化する）。呼び出し側は返された一時ファイルを
    /// 移動するか削除する責任を持つ。
    ///
    /// onProgress は 0...1（総量不明時は最後に 1.0 のみ）。
    /// shouldCancel: 非 nil の場合、受信中に true を返すと即座に CancellationError で中断する
    /// （ダウンロードの即時キャンセル用。バイトストリームは MainActor 外で回るため、呼び出し側は
    /// スレッド安全なトークンを渡すこと。Task.isCancelled には依存しない）。
    /// 中断・失敗のどの経路でも一時ファイルは残さない。
    public func bookFile(libraryUUID: String, bookID: Int, libraryToken: String?,
                         onProgress: (@Sendable (Double) -> Void)?,
                         shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> URL {
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
            case 403: throw RemoteClientError.forbidden(headers: Self.headerMap(http))
            case 404: throw RemoteClientError.notFound
            default: throw RemoteClientError.server(http.statusCode)
            }
        } else {
            throw RemoteClientError.badResponse
        }
        let total = response.expectedContentLength   // 不明は -1
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacknest-dl-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw RemoteClientError.badResponse
        }
        let handle = try FileHandle(forWritingTo: tmp)
        // 成功時のみ呼び出し側へ所有権を渡す。中断・失敗のどの経路でも残骸を作らない。
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: tmp) }
        }
        // 1 バイトずつ書くと syscall が支配的になるため 64KiB 単位でまとめて flush する。
        var buffer = Data()
        buffer.reserveCapacity(Self.flushChunkBytes)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            // #12: 宣言 Content-Length の真偽に関わらず、実受信量そのものに上限を課す。
            if Self.exceedsMaxDownloadBytes(received: received) { throw RemoteClientError.responseTooLarge }
            if buffer.count >= Self.flushChunkBytes {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                // 即時キャンセル: トークンが立っていれば受信を打ち切る（in-flight 中断）。
                if shouldCancel?() == true { throw CancellationError() }
                if let f = Self.downloadFraction(received: received, total: total) {
                    onProgress?(f)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        // 受信ループに一度も入らない（0 バイト）場合もキャンセルを尊重する。
        if shouldCancel?() == true { throw CancellationError() }
        onProgress?(1.0)
        completed = true
        return tmp
    }

    /// G23 (M2): ディスクへ流す際のバッファサイズ。進捗通知とキャンセル判定もこの粒度で行う。
    static let flushChunkBytes = 65536

    /// review follow-up Finding 1（cover 経路の確認）: この呼び出しは `?v=` を一切送らない
    /// （引数にも version が無い）ため、サーバの `cacheableImageResponse` は常に
    /// `requestedVersion == nil` の分岐を通り `cacheable=true`（`Cache-Control: immutable`）
    /// のままになる ―― つまり native の表紙取得はそもそも `no-store` を受け取り得ない。
    /// `RemoteCoverCache.data`/`RemotePageCache.data(for:fetch:)` がこの結果を無条件に
    /// L1/L2 へ store しても、pageData と同種の「誤った版キーへのバイト固定」は起きない
    /// （表紙差し替え時のキャッシュ無効化は `RemoteCoverCache.invalidate` が別途担っている）。
    /// よってページ画像と異なり、cover 側には no-store 伝播の追加対応は不要（確認済み）。
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

    /// G17 T6b: 特定ページの単頁/見開き override をサーバへ POST する（RW トークン必須）。
    /// mode: 0=forcePair / 1=forceSolo / nil=クリア（自動判定に戻す）。
    public func setPageOverride(libraryUUID: String, bookID: Int, page: Int, mode: Int?, libraryToken: String?) async throws {
        struct PageLayoutBody: Encodable { let page: Int; let mode: Int? }
        let body = try JSONEncoder().encode(PageLayoutBody(page: page, mode: mode))
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/page-layout")
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
    /// G12b-3c S5: 応答は削除した行を BookRestoreDTO として返す（リモート undo で復元に使う）。
    @discardableResult
    public func deleteBook(libraryUUID: String, bookID: Int, trash: Bool, libraryToken: String?) async throws -> BookRestoreDTO {
        let q = trash ? [URLQueryItem(name: "trash", value: "1")] : []
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)", query: q)
        let data = try await send(request(url, method: "DELETE", libraryToken: libraryToken))
        return try decode(BookRestoreDTO.self, data)
    }

    /// POST /api/v1/libraries/:lib/books/restore — deleteBook が返した BookRestoreDTO を渡して復元する（RW/admin）。
    /// リモート undo（削除の取り消し）用。G16 A1: 応答の `restored`（実際に復元できた件数）を返し、
    /// 呼び出し側が 0 件（＝取り消し失敗）を判定できるようにする。
    @discardableResult
    public func restoreBooks(_ dtos: [BookRestoreDTO], libraryUUID: String, libraryToken: String?) async throws -> RestoreResultDTO {
        let url = makeURL("libraries/\(libraryUUID)/books/restore")
        let body = try JSONEncoder().encode(dtos)
        let data = try await send(request(url, method: "POST", libraryToken: libraryToken,
                                          body: body, contentType: "application/json", timeout: 30))
        return try decode(RestoreResultDTO.self, data)
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

    /// G21 #5: 1 冊の表紙を今のファイルから作り直す。外部表紙の本ではサーバ側で no-op（現状の DTO を返す）。
    @discardableResult
    public func regenerateCover(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> BookDetailDTO {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover/regenerate")
        // アーカイブから抽出＋縮小＋書き込みを経て応答するため cover-image と同様に長め（30s）を渡す。
        let data = try await send(request(url, method: "POST", libraryToken: libraryToken, timeout: 30))
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
                        case 403: continuation.finish(throwing: RemoteClientError.forbidden(headers: Self.headerMap(http))); return
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
