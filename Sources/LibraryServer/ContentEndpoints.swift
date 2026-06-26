// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import LibraryStore
import AppCore
import Hummingbird
import LibraryServerAPI

/// 本の原本ファイルの mtime+size から弱 ETag を作る（spec §3.3）。
/// fileMtime/fileSize は contentHash 計算時に記録される列で、未計算の本では 0 にフォールバックする。
func bookETag(for row: BookRow) -> String {
    let mtime = row.fileMtime ?? 0
    let size = row.fileSize ?? 0
    return "\"\(row.id)-\(Int(mtime))-\(size)\""
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

/// ETag/immutable 付き画像レスポンス。If-None-Match 一致なら 304。
func cacheableImageResponse(data: Data, etag: String, request: Request) -> Response {
    if request.headers[.ifNoneMatch] == etag {
        return Response(status: .notModified)
    }
    var headers = HTTPFields()
    headers[.eTag] = etag
    headers[.cacheControl] = "private, max-age=31536000, immutable"
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
}
