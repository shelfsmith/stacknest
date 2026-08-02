// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryServerAPI

/// リモートサーバの 1 冊を BookContent として供給する。既存 ViewerWindowController が
/// そのまま使える（pageCount=manifest / imageData=GET /pages/:n?maxw=）。
public struct RemoteBookContent: BookContent {
    private let client: RemoteLibraryClient
    private let serverID: UUID
    private let libraryUUID: String
    private let bookID: Int
    private let libraryToken: String?
    private let maxWidth: Int?
    /// G4d 層2: ページの版トークン（manifest.etag ＝ bookETag）。relink 等でサーバの本体が
    /// 差し替わると etag が変わるため、旧版のページキャッシュを引かず素通しで再取得させる。
    /// nil ＝旧来の版なしキー（後方互換。manifest 取得に失敗した場合のフォールバック）。
    private let version: String?
    private let cache: RemotePageCache?

    public init(client: RemoteLibraryClient, serverID: UUID, libraryUUID: String, bookID: Int,
                libraryToken: String?, maxWidth: Int?, version: String? = nil, cache: RemotePageCache? = .shared) {
        self.client = client
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.libraryToken = libraryToken
        self.maxWidth = maxWidth
        // レビュー Minor4 fix: manifest.etag は HTTP ETag 形式で前後にダブルクォートを含む
        // （例 `"5-1700000000-1234-abc"` ＝クォート文字そのものが String の中身）。素通しすると
        // キャッシュキーが `...|v"5-…"` のように汚れる。version が native クライアントへ入る唯一の
        // 入口はこの init（呼び出し元は RemoteLibraryState.swift の2箇所のみ、いずれも m.etag を渡す）
        // なので、正規化はここ一箇所で行えば imageData の Key・versionValue 経由の setProtected・
        // cachedPages が全て同じ正規化済み値を見ることになり、版の食い違いが起きない。
        self.version = Self.normalizeVersion(version)
        self.cache = cache
    }

    /// ETag の前後の `"` を剥がす。ETag でない/クォートが無い値はそのまま返す（防御的・後方互換）。
    static func normalizeVersion(_ raw: String?) -> String? {
        guard let raw, raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    public var pageCount: Int {
        get async throws {
            try await client.manifest(libraryUUID: libraryUUID, bookID: bookID, libraryToken: libraryToken).pageCount
        }
    }

    /// G26: サーバ側で部分読みになった本の注意文。manifest から受け取る。
    /// 旧サーバはキーを返さないので nil になり、何も表示されない（後方互換）。
    public var damageNote: String? {
        get async {
            try? await client.manifest(libraryUUID: libraryUUID, bookID: bookID,
                                       libraryToken: libraryToken).damageNote
        }
    }

    public func imageData(at page: Int) async throws -> Data {
        let client = self.client, uuid = self.libraryUUID, bid = self.bookID
        let token = self.libraryToken, mw = self.maxWidth, ver = self.version
        // HTTP キャッシュ追随修正: URL に載せる版は必ずキャッシュキー(key.version)と同じ
        // self.version（正規化済み）を使う。ここで別の値を作ると、URL 版とキャッシュキー版が
        // ずれて本 bug と同種の不整合が再発する。
        // review follow-up Finding 1: pageData の noStore（サーバが Cache-Control: no-store
        // で返した＝?v= が現在版と食い違う）を cacheable の否定として RemotePageCache へ伝え、
        // 誤った版キーの下へバイトが永続化されるのを防ぐ（詳細は RemotePageCache.data(for:fetch:)
        // の tuple オーバーロードのコメント参照）。
        let fetch: @Sendable () async throws -> (data: Data, cacheable: Bool) = {
            let (data, noStore) = try await client.pageData(libraryUUID: uuid, bookID: bid, index: page, maxw: mw, version: ver, libraryToken: token)
            return (data, !noStore)
        }
        guard let cache else { return try await fetch().data }
        let key = RemotePageCache.Key(serverID: serverID, libraryUUID: uuid, bookID: bid, kind: .page, page: page, maxw: mw, version: version)
        return try await cache.data(for: key, fetch: fetch)
    }

    /// G3b: RemotePrefetchContext から保護キーを組み立てるため bookID を公開する。
    public var bookIDValue: Int { bookID }
    /// G4d 層2: 可視保護キーが imageData(at:) と同じ版キーを組み立てられるよう version を公開する。
    public var versionValue: String? { version }
}
