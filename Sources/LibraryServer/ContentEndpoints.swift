// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import LibraryStore
import AppCore
import Hummingbird
import LibraryServerAPI

/// 本の原本の mtime/size を返す。
///
/// **存在するパスは種別を問わず request 時に live stat する**（G27a ③）。
/// 以前はディレクトリのときだけ live stat し、ファイルは DB の file_mtime/file_size に
/// フォールバックしていた。しかしこの 2 列は contentHash 計算時にしか埋まらず、実機では
/// 99.5% の本で NULL である。結果 `(nil, nil)` → bookETag が `<id>-0-0` に固定され、
/// **ファイルを差し替えても ETag が変わらず古い内容が配信され続けていた。**
/// コストは 1 リクエストあたり stat 1 回で、manifest / ページ配信の頻度なら無視できる。
func effectiveFileStat(for row: BookRow) -> (mtime: Double?, size: Int64?) {
    if let path = row.path, FileManager.default.fileExists(atPath: path) {
        let (statSize, statMtime) = Database.statFile(path)
        if statMtime != nil || statSize != nil {
            return (statMtime, statSize)
        }
        // stat 失敗 → stored 値へフォールバック（下の分岐へ落ちる）
    }
    if let mtime = row.fileMtime, let size = row.fileSize {
        return (mtime, size)
    }
    return (nil, nil)
}

/// 本の原本ファイルの mtime+size+path から弱 ETag を作る（spec §3.3, G4d）。
/// path を織り込むことで、relink 直後に mtime/size が万一 nil でも etag が変わり、
/// また異なるパスの book が "id-0-0" で衝突しない。
/// fileMtime/fileSize は contentHash 計算時に記録される列だが、実在するパスは種別を問わず
/// effectiveFileStat が request 時 stat で埋める（G27a ③）。stat も失敗し stored 値も無い本のみ
/// 0 にフォールバックする。
func bookETag(for row: BookRow) -> String {
    let (mtimeOpt, sizeOpt) = effectiveFileStat(for: row)
    let mtime = mtimeOpt ?? 0
    let size = sizeOpt ?? 0
    let pathHash = String(fnv1aHash(row.path ?? ""), radix: 36)
    return "\"\(row.id)-\(Int(mtime))-\(size)-\(pathHash)\""
}

/// FNV-1a 64bit hash（プロセスをまたいで安定 = Swift の `String.hashValue` は per-process seed
/// のため使えない。bookETag が再起動のたびに変わって 304 revalidation が壊れるのを防ぐ）。
/// 文字列の UTF-8 バイト列に対して計算する。
func fnv1aHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV offset basis
    let prime: UInt64 = 0x0000_0100_0000_01B3  // FNV prime
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* prime
    }
    return hash
}

/// 表紙ファイル自身の mtime+size 由来 ETag（表紙差し替えを追跡 — 4.1a 最終レビュー引き継ぎ(1)）。
/// 原本 mtime ベースの bookETag では「原本据え置きで表紙だけ再生成」を検知できないため、
/// thumbnail.jpg 自身の属性を見る。属性取得失敗（表紙なし等）は nil を返し呼び出し側で fallback。
func thumbnailETag(url: URL, bookID: Int) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
          let size = attrs[.size] as? Int64 else { return nil }
    return "\"c\(bookID)-\(Int(mtime))-\(size)\""
}

/// 表紙ファイル URL の解決。
/// 実規約（CoverRefresher / ThumbnailLoader / LibraryBundle）はファイル名固定:
///   <bundle>/Thumbnails/<bookID>/thumbnail.jpg
/// `BookRow.coverImageName` はアーカイブ内エントリ名（手動表紙の選択記録）であって
/// ディスク上のファイル名ではないため、ここでは参照しない（自動表紙の本は nil のまま表紙を持つ）。
func coverURL(bundleURL: URL, bookID: Int) -> URL {
    bundleURL
        .appendingPathComponent("Thumbnails")
        .appendingPathComponent("\(bookID)")
        .appendingPathComponent("thumbnail.jpg")
}

/// PageDirection → Web クライアント向け安定文字列（enum 改名に脆い String(describing:) は使わない）。
func directionString(_ direction: PageDirection) -> String {
    switch direction {
    case .rightToLeft: return "rtl"
    case .leftToRight: return "ltr"
    }
}

/// BookCategory → Web クライアント向け安定文字列（明示 switch・plan 設計ノート）。
func formatString(_ category: BookCategory) -> String {
    switch category {
    case .archive: return "archive"
    case .image: return "image"
    case .folder: return "folder"
    case .video: return "video"
    case .text: return "text"
    }
}

/// 画像バイト列から Content-Type を判定（FFD8→jpeg / 8950→png / その他→octet-stream）。
func sniffImageContentType(_ data: Data) -> String {
    if data.prefix(2) == Data([0xFF, 0xD8]) { return "image/jpeg" }
    if data.prefix(2) == Data([0x89, 0x50]) { return "image/png" }
    return "application/octet-stream"
}

/// maxw 指定時は ETag に幅を織り込み、原寸版と別キャッシュキーにする。
/// base は引用符で囲まれた弱 ETag（例 "abc"）。閉じ引用符の手前に -w<n> を差し込む。
func maxwETag(_ base: String, maxw: Int?) -> String {
    guard let maxw, maxw > 0 else { return base }
    if base.hasSuffix("\"") {
        return String(base.dropLast()) + "-w\(maxw)\""
    }
    return base + "-w\(maxw)"
}

/// クライアント側 normalizeVersion（Sources/RemoteClient/RemoteBookContent.swift の
/// `RemoteBookContent.normalizeVersion` / Sources/LibraryServer/Resources/web/reader.js の
/// `normalizeVersion`）と**同じ規約**で ETag の前後の `"` を剥がす。`?v=` に載る値は常にこの
/// 正規化を経ているため、サーバ側で比較する際も同じ変換をかけないと絶対に一致しない
/// （Finding 1: ?v= 検証の比較関数）。
func stripETagQuotes(_ raw: String) -> String {
    guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
    return String(raw.dropFirst().dropLast())
}

/// ETag/immutable 付き画像レスポンス。If-None-Match 一致なら 304。
/// `cacheable=false`（Finding 1: リクエストの `?v=` が現在の版と食い違う）のときは
/// Cache-Control を `no-store` に差し替える。中身は常に「今の正しいバイト」を返す
/// （404/409 にはしない）。
/// この `no-store` はあくまで HTTP キャッシュ層（ブラウザ/URLSession の URLCache）を
/// 無効化するだけで、クライアントのアプリ内バイトキャッシュ（web IndexedDB / native
/// RemotePageCache）には自動では及ばない ―― サーバはヘッダを立てるところまでしかできず、
/// 実際に「保存しない」を実行するのは各クライアントの責務（review follow-up Finding 1）。
/// ページ画像は web 側 `Resources/web/prefetch.js`（`fetchPageBlob` の cache-control 判定→
/// `putPage` をスキップ）、native 側 `RemoteBookContent.imageData` 経由の
/// `RemoteLibraryClient.pageData`（`Cache-Control` を見て `RemotePageCache` への `store` を
/// スキップ）がそれぞれこの応答を見て IndexedDB/RemotePageCache への永続化を止めることで、
/// 誤った版キーの下へバイトが固定されるのを防いでいる。
/// 表紙はこの経路の対象外: native の cover 取得（`RemoteLibraryClient.coverData`）はそもそも
/// `?v=` を送らないため常に cacheable=true になり、web の表紙は `<img src>` 経由でブラウザ
/// HTTP キャッシュのみに依存しアプリ内バイトキャッシュを持たないため、この no-store は
/// HTTP キャッシュに対してのみ効けば十分＝クライアント側の追加対応は不要（確認済み）。
/// v が無い（旧クライアント/version 不明フォールバック）ときは cacheable=true のまま
/// 呼び出す＝挙動は今日と完全に同じ。
func cacheableImageResponse(data: Data, etag: String, request: Request, cacheable: Bool = true) -> Response {
    if request.headers[.ifNoneMatch] == etag {
        return Response(status: .notModified)
    }
    var headers = HTTPFields()
    headers[.eTag] = etag
    headers[.cacheControl] = cacheable
        ? "private, max-age=31536000, immutable"
        : "no-store"
    headers[.contentType] = sniffImageContentType(data)
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

extension LibraryResolver {
    /// :lib/:id を解決して (ライブラリ, 本) を返す。
    /// 不明 uuid / スコープ外 / 不明 book id → 404、ロック庫の未解錠 → LibraryAccessError.locked（403）。
    func resolveBook(
        _ request: Request, _ context: some RequestContext & RoleHoldingContext
    ) async throws -> (ServedLibrary, BookRow) {
        let uuid = try context.parameters.require("lib")
        guard let lib = try await resolve(
            uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
        ) else { throw HTTPError(.notFound) }
        let id = try context.parameters.require("id", as: Int.self)
        guard let row = try lib.db.fetchBook(id: id) else { throw HTTPError(.notFound) }
        return (lib, row)
    }

    /// :lib を解決してライブラリを返す。
    /// 不明 uuid / スコープ外 → 404、ロック庫の未解錠 → LibraryAccessError.locked（403）。
    func resolveLibrary(
        _ request: Request, _ context: some RequestContext & RoleHoldingContext
    ) async throws -> ServedLibrary {
        let uuid = try context.parameters.require("lib")
        guard let lib = try await resolve(
            uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
        ) else { throw HTTPError(.notFound) }
        return lib
    }
}
