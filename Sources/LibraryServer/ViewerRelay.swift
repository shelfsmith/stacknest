// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import AppCore

/// G60 v3（spec §5.8・試用）: 127.0.0.1 の口でリモートの本を中継するための設定。共有サーバには付けない
/// （`LibraryServerConfig.relayConfigurationIsValid`）。
///
/// 口を起動し直すたびに作らず、口の持ち主（`LocalControlController`）が 1 つだけ持つ
/// （`session` は invalidate しないので、作るたびに残る）。
public struct ViewerRelayConfig: Sendable {
    /// 取り次ぐ応答の本文の上限の既定（ページの画像が収まる大きさ）。超えたら 502。
    public static let defaultMaxResponseBytes = 64 * 1024 * 1024
    /// ビューアから受ける POST（progress）の本文の上限の既定。超えたら 413（リモートへは送らない）。
    public static let defaultMaxRequestBytes = 64 * 1024

    public let registry: ViewerRelayRegistry
    /// 取り次ぎに使う URLSession。テストは URLProtocol を差した session を渡す。
    public let session: URLSession
    /// 取り次ぐ応答の本文の上限（バイト）。逐次に数え、超えた時点で打ち切って 502。
    public let maxResponseBytes: Int
    /// ビューアから受ける POST の本文の上限（バイト）。超えたら 413。
    public let maxRequestBytes: Int
    /// G60 §5.9: 内蔵ビューアと分け合うページのキャッシュ。nil なら `pages/{n}` も今までどおり素通し（§5.8 の形）。
    public let pageCache: (any ViewerRelayPageCache)?
    /// G60 §5.9: 同じページを同時に頼まれたら 1 回だけ取る。
    let loader: ViewerRelayPageLoader
    /// G60 §5.9: 渡した本の先読み（キャッシュを使う形だけ。1 冊ずつ。範囲は `wholeBookPrefetch` に従う）。
    public let prefetcher: ViewerRelayPrefetcher?
    /// G60 §5.9: 先読みの範囲の設定（先読み係に渡したものと同じ閉包。配線をテストで確かめるために公開する）。
    public let wholeBookPrefetch: @Sendable () -> Bool

    /// - Parameter wholeBookPrefetch: 内蔵ビューアと同じ設定「開いた本を全ページ先読みする」が今 ON か
    ///   （先読み係が取るページを選ぶたびに読む。App は `RemoteCacheSettings.wholeBookPrefetch()` を渡す。既定は OFF）。
    public init(registry: ViewerRelayRegistry, session: URLSession = ViewerRelayConfig.defaultSession(),
                maxResponseBytes: Int = ViewerRelayConfig.defaultMaxResponseBytes,
                maxRequestBytes: Int = ViewerRelayConfig.defaultMaxRequestBytes,
                pageCache: (any ViewerRelayPageCache)? = nil,
                prefetchTuning: ViewerRelayPrefetcher.Tuning = ViewerRelayPrefetcher.Tuning(),
                wholeBookPrefetch: @escaping @Sendable () -> Bool = { false }) {
        self.registry = registry
        self.session = session
        self.maxResponseBytes = maxResponseBytes
        self.maxRequestBytes = maxRequestBytes
        self.pageCache = pageCache
        self.wholeBookPrefetch = wholeBookPrefetch
        let loader = ViewerRelayPageLoader()
        self.loader = loader
        self.prefetcher = pageCache.map { cache in
            ViewerRelayForwarder.makePrefetcher(registry: registry, session: session, limit: maxResponseBytes,
                                                cache: cache, loader: loader, tuning: prefetchTuning,
                                                wholeBook: wholeBookPrefetch)
        }
    }

    /// G60 §5.9: 渡した本の先読みを始める（前に渡した本の先読みは止まる）。`focus` は開くページ。
    /// 範囲は設定に従う（ON＝全ページ・OFF＝近傍だけ）。キャッシュを使わない形では何もしない。
    public func startPrefetch(relayID: String, focus: Int) async {
        await prefetcher?.start(relayID: relayID, focus: focus)
    }

    /// G60 §5.9: 先読みを止める（127.0.0.1 の口を止めたとき・StackNest の終了）。
    public func stopPrefetch() async {
        await prefetcher?.stop()
    }

    /// G60 §5.9: 「開いた本を全ページ先読みする」が切り替わった（App が設定の画面の知らせを受けて呼ぶ）。
    public func wholeBookPrefetchSettingChanged() async {
        await prefetcher?.wholeBookSettingChanged()
    }

    /// キャッシュ・Cookie を持たない session（ETag と 304 はビューアとリモートの間でそのまま通す）。
    /// 無通信の時間切れ（30 秒）に加えて、1 要求の全体にも上限（120 秒）を置く（少しずつ送り続ける相手で
    /// 口の接続を長く塞がない）。
    public static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }
}

/// G60 v3（spec §5.8・試用）: 中継の鍵で来た要求を、リモートの鍵を付けてリモートのサーバへ取り次ぐ。
///
/// リモートの鍵は `URLRequest` の `Authorization` にだけ載せる。失敗はどれも状態コードだけを返し、
/// 鍵・URL・本文をログやエラーに出さない。
enum ViewerRelayForwarder {
    /// ビューアへ写し返す応答のヘッダ（許可リスト）。`Content-Length`・`Content-Encoding` は写さない
    /// （URLSession は圧縮を解いた本文を返すので、写すと食い違う）。`Set-Cookie` などほかのヘッダも写さない。
    static let copiedResponseHeaders = ["Content-Type", "ETag", "X-Library-Locked"]

    /// URLSession が辿ろうとしたリダイレクトを拒む（鍵を別のオリジンへ運ばない。同じオリジンでも辿らない）。
    class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// 取り次ぎの結果。
    enum Outcome: Sendable {
        case response(HTTPURLResponse, Data)
        /// 本文が上限を超えた（`Content-Length` で先に分かった、または受けている途中で超えた）。
        case tooLarge
        /// 中継先に届かない・時間切れ・取り消し。
        case failed
    }

    /// 応答の本文を上限まで逐次に受ける作業ごとの delegate。上限を超えたら、その時点で作業を取り消す
    /// （全部をメモリに受けてから数えるのではない）。リダイレクトは辿らない（`RefuseRedirects`）。
    ///
    /// `@unchecked Sendable`: 可変の状態はすべて `NSLock` で直列化している（URLSession の delegate の列と
    /// 呼び出し側の Task の両方から触る）。
    final class BoundedLoader: RefuseRedirects, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let lock = NSLock()
        private var received = Data()
        private var overflowed = false
        private var continuation: CheckedContinuation<Outcome, Never>?
        /// 継続を置く前に届いた完了の結果（Codex P2）。呼び出し側の取り消しで `task.cancel()` が先に走ると、
        /// `start` より前に `didCompleteWithError` が来ることがある。捨てると `load` が待ち続けるので、ここに預ける。
        private var earlyOutcome: Outcome?

        init(limit: Int) {
            self.limit = limit
        }

        /// 作業を始める。結果は `didCompleteWithError` で 1 回だけ返す。
        /// 完了が先に届いていたら、作業は始めずにその結果をすぐ返す。
        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Outcome, Never>) {
            let early: Outcome? = lock.withLock {
                if let early = earlyOutcome {
                    earlyOutcome = nil
                    return early
                }
                self.continuation = continuation
                return nil
            }
            if let early {
                continuation.resume(returning: early)
                return
            }
            task.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            // 長さが分かっていて上限を超えるなら、本文を読む前に打ち切る（-1 は不明＝受けながら数える）。
            if response.expectedContentLength > Int64(limit) {
                lock.withLock { overflowed = true }
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let exceeded: Bool = lock.withLock {
                guard !overflowed else { return false }
                if received.count + data.count > limit {
                    overflowed = true
                    received = Data()
                    return true
                }
                received.append(data)
                return false
            }
            if exceeded { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (cont, result): (CheckedContinuation<Outcome, Never>?, Outcome) = lock.withLock {
                let result: Outcome
                if overflowed {
                    result = .tooLarge
                } else if error != nil {
                    result = .failed
                } else if let http = task.response as? HTTPURLResponse {
                    result = .response(http, received)
                } else {
                    result = .failed
                }
                received = Data()
                let cont = continuation
                continuation = nil
                if cont == nil { earlyOutcome = result }
                return (cont, result)
            }
            cont?.resume(returning: result)
        }
    }

    /// 1 要求を取り次ぎ、上限を守って結果を返す。呼び出し側の Task が取り消されたら作業も取り消す。
    static func load(_ request: URLRequest, session: URLSession, limit: Int) async -> Outcome {
        let loader = BoundedLoader(limit: limit)
        let task = session.dataTask(with: request)
        task.delegate = loader
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loader.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 中継の鍵（その relayID のもの）と中継の記録を確かめる。CLI・MCP のトークン（viewerBook が無い）・本の鍵
    /// （relayID が無い）・別の中継の鍵は 403、記録が無い（StackNest を終了した後）・期限切れは 401。
    /// G60 §5.9: **キャッシュはこれを通った後でだけ引く**（`handlePage`）。
    static func authorize(_ context: some RequestContext & RoleHoldingContext,
                          relay: ViewerRelayConfig) throws -> (relayID: String, target: ViewerRelayTarget) {
        let relayID = try context.parameters.require("relayID")
        // 多層防御: 道の許可リスト（ViewerTokenRoutes.allowsRelay）に加えて、ここでも鍵の中継を照らす。
        guard let access = context.viewerBook, access.relayID == relayID else { throw HTTPError(.forbidden) }
        // 中継の記録が無い（StackNest を終了した後・上流に断られて閉じた）・期限が切れた → 401（「StackNest から開き直して」）。
        guard let target = relay.registry.target(for: relayID) else { throw HTTPError(.unauthorized) }
        return (relayID, target)
    }

    /// 中継のルートの本体（`manifest`・`cover`・`progress`。`pages/{n}` は `handlePage`）。
    static func handle(_ request: Request, _ context: some RequestContext & RoleHoldingContext, remotePath: String,
                       relay: ViewerRelayConfig) async throws -> Response {
        let (relayID, target) = try authorize(context, relay: relay)
        var body: ByteBuffer?
        if request.method == .post {
            // 上限を超えたら 413（NIOTooManyBytesError）。リモートへは何も送らない。
            body = try await request.body.collect(upTo: relay.maxRequestBytes)
        }
        // G60 §5.9: 素通しした manifest に、中継の記録のページ数と版を合わせる（キャッシュを使う形だけ）。
        var onSuccess: (@Sendable (Data) async -> Void)?
        if remotePath == "manifest" && relay.pageCache != nil {
            onSuccess = { @Sendable data in await ViewerRelayForwarder.noteManifest(data, relayID: relayID, relay: relay) }
        }
        let response = await forward(target, remotePath: remotePath, request: request, body: body, relay: relay,
                                     onSuccess: onSuccess)
        // 作者の決定（2026-10-10・Codex P1）: manifest・cover・progress で断られても、その中継を閉じる。
        closeIfRefused(Int(response.status.code), relayID: relayID, registry: relay.registry)
        return response
    }

    /// 取り次ぐ URL と要求を部品から組み直す（ビューアの要求をそのまま流さない）。
    /// - `remotePath` はルートごとの固定の文字列か `pages/<Int>`。
    /// - クエリは正の整数の `maxw` と、manifest の `pageNames=1`（外部ビューアのページの名前）だけを渡す
    ///   （ほかのクエリ・数でない値・0 以下・ほかの道の `pageNames` は落とす）。
    /// - ヘッダは許可リスト: `Authorization`（リモートの鍵に付け替え）・`X-StackNest-Viewer`（整えてから）・
    ///   `If-None-Match`・POST の `Content-Type`。`Cookie`・`Range`・`X-Library-Token` などは渡さない。
    static func makeRemoteRequest(_ target: ViewerRelayTarget, remotePath: String, request: Request,
                                  body: ByteBuffer?) -> URLRequest? {
        guard var components = URLComponents(string: target.remoteBookURL + "/" + remotePath) else { return nil }
        var items: [URLQueryItem] = []
        if let maxw = request.uri.queryParameters.get("maxw", as: Int.self), maxw > 0 {
            items.append(URLQueryItem(name: "maxw", value: String(maxw)))
        }
        if remotePath == "manifest", request.uri.queryParameters.get("pageNames") == "1" {
            items.append(URLQueryItem(name: "pageNames", value: "1"))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return nil }
        var outgoing = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        outgoing.httpMethod = request.method.rawValue
        outgoing.httpShouldHandleCookies = false
        // ビューアの中継の鍵は渡さない。リモートの鍵に付け替える。
        outgoing.setValue("Bearer \(target.remoteToken)", forHTTPHeaderField: "Authorization")
        // 名乗りは保存のときと同じ規則で整えてから渡す（相手のログや保存に制御文字を運ばない）。
        if let viewer = StackNestViewerIdentification.sanitizeForStorage(request.headers[ViewerTokenRoutes.identificationHeader]) {
            outgoing.setValue(viewer, forHTTPHeaderField: StackNestViewerIdentification.headerName)
        }
        if let etag = request.headers[.ifNoneMatch] {
            outgoing.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let body {
            outgoing.httpBody = Data(body.readableBytesView)
            outgoing.setValue(request.headers[.contentType] ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return outgoing
    }

    /// - Parameter onSuccess: リモートが 200 を返したとき、応答を組む前に本文で呼ぶ（G60 §5.9: manifest の追従）。
    static func forward(_ target: ViewerRelayTarget, remotePath: String, request: Request,
                        body: ByteBuffer?, relay: ViewerRelayConfig,
                        onSuccess: (@Sendable (Data) async -> Void)? = nil) async -> Response {
        guard let outgoing = makeRemoteRequest(target, remotePath: remotePath, request: request, body: body) else {
            return Response(status: .badGateway)
        }
        let http: HTTPURLResponse
        let data: Data
        switch await load(outgoing, session: relay.session, limit: relay.maxResponseBytes) {
        case .response(let response, let received):
            http = response
            data = received
        case .tooLarge, .failed:
            // 上限超え・中継先に届かない・時間切れ。鍵や URL はログに出さない。
            return Response(status: .badGateway)
        }
        // リダイレクトは取り次がない（304 は ETag の再検証なのでそのまま返す）。
        if (300...399).contains(http.statusCode), http.statusCode != 304 { return Response(status: .badGateway) }
        if http.statusCode == 200, let onSuccess { await onSuccess(data) }
        return Response(status: HTTPResponse.Status(code: http.statusCode), headers: copiedHeaders(http),
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// ビューアへ写し返すヘッダ（許可リスト `copiedResponseHeaders` だけ）。
    static func copiedHeaders(_ http: HTTPURLResponse) -> HTTPFields {
        var headers = HTTPFields()
        for name in copiedResponseHeaders {
            if let value = http.value(forHTTPHeaderField: name), let field = HTTPField.Name(name) {
                headers[field] = value
            }
        }
        return headers
    }
}
