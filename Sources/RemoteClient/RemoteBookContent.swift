// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryServerAPI

/// G26 Codex Important #3: manifest **1 レスポンス分**のスナップショット。
///
/// 以前は `pageCount` と `damageNote` が別々の manifest リクエストで取られていた。
/// `damageNote` 側だけが一時的に失敗すると `try?` が nil を返し、呼び出し側は
/// 「破損していない本」として開いてしまう —— つまりネットワークが一瞬揺れただけで
/// `TruncatedReadPolicy` のゲートが無効化され、クランプした位置が書き戻される。
/// ページ数・破損注意文・override・ETag は**同じ 1 回の manifest から**取り、以後は
/// この値の束としてだけ受け渡す（同時に往復も 1 回に減る）。
///
/// 取得できなかった場合にこの型を「空で」でっち上げてはならない。呼び出し側は
/// **開かない**（fail safe）こと。
public struct RemoteBookSnapshot: Sendable {
    public let pageCount: Int
    /// 破損（打ち切り読み）注意文。nil ＝打ち切りではない。
    public let damageNote: String?
    /// G17 T6b: ページ単位の単頁/見開き override（page_index(String) → mode）。
    public let pageOverrides: [String: Int]?
    /// G4d 層2: ページの版トークン（manifest.etag ＝ bookETag）。
    public let etag: String?

    public init(pageCount: Int, damageNote: String? = nil,
                pageOverrides: [String: Int]? = nil, etag: String? = nil) {
        self.pageCount = pageCount
        self.damageNote = damageNote
        self.pageOverrides = pageOverrides
        self.etag = etag
    }

    /// 実 manifest からの唯一の変換口。ここ以外でスナップショットを組み立てないこと。
    public init(manifest: ManifestDTO) {
        self.init(pageCount: manifest.pageCount, damageNote: manifest.damageNote,
                  pageOverrides: manifest.pageOverrides, etag: manifest.etag)
    }
}

/// リモートサーバの 1 冊を BookContent として供給する。既存 ViewerWindowController が
/// そのまま使える（pageCount/damageNote=注入済み manifest スナップショット・
/// imageData=GET /pages/:n?maxw=）。
public struct RemoteBookContent: BookContent {
    private let client: RemoteLibraryClient
    private let serverID: UUID
    private let libraryUUID: String
    private let bookID: Int
    private let libraryToken: String?
    private let maxWidth: Int?
    /// G26 Codex Important #3: 開いた時点の manifest スナップショット（必須）。
    /// pageCount / damageNote / version はすべてここから読む＝**必ず同じ manifest 由来**になる。
    private let snapshot: RemoteBookSnapshot
    /// G4d 層2: ページの版トークン（manifest.etag ＝ bookETag）。relink 等でサーバの本体が
    /// 差し替わると etag が変わるため、旧版のページキャッシュを引かず素通しで再取得させる。
    /// nil ＝旧来の版なしキー（後方互換。ETag を持たないスナップショットの場合）。
    private let version: String?
    private let cache: RemotePageCache?

    public init(client: RemoteLibraryClient, serverID: UUID, libraryUUID: String, bookID: Int,
                libraryToken: String?, maxWidth: Int?, snapshot: RemoteBookSnapshot,
                cache: RemotePageCache? = .shared) {
        self.client = client
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.libraryToken = libraryToken
        self.maxWidth = maxWidth
        self.snapshot = snapshot
        let version = snapshot.etag
        // レビュー Minor4 fix: manifest.etag は HTTP ETag 形式で前後にダブルクォートを含む
        // （例 `"5-1700000000-1234-abc"` ＝クォート文字そのものが String の中身）。素通しすると
        // キャッシュキーが `...|v"5-…"` のように汚れる。version が native クライアントへ入る唯一の
        // 入口はこの init（版は必ずスナップショットの etag から来る）なので、正規化はここ一箇所で
        // 行えば imageData の Key・versionValue 経由の setProtected・cachedPages が全て同じ
        // 正規化済み値を見ることになり、版の食い違いが起きない。
        self.version = Self.normalizeVersion(version)
        self.cache = cache
    }

    /// ETag の前後の `"` を剥がす。ETag でない/クォートが無い値はそのまま返す（防御的・後方互換）。
    static func normalizeVersion(_ raw: String?) -> String? {
        guard let raw, raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    /// G26 Codex Important #3: 開いた時点のスナップショットから返す（**追加の往復をしない**）。
    /// 以前はここで manifest を取り直していたため、`damageNote` 用の取得と別レスポンスになり、
    /// 片方だけ失敗すると打ち切り判定とページ数が食い違いえた。
    public var pageCount: Int {
        get async throws { snapshot.pageCount }
    }

    /// G26: サーバ側で部分読みになった本の注意文。`pageCount` と**同じ** manifest から来る。
    /// 旧サーバはキーを返さないので nil になり、何も表示されない（後方互換）。
    public var damageNote: String? {
        get async { snapshot.damageNote }
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
