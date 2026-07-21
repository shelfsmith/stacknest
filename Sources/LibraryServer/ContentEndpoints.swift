// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import LibraryStore
import AppCore
import Hummingbird
import LibraryServerAPI

/// row の file_mtime/file_size が両方揃っていればそのまま返す。
/// どちらか nil の場合は、row.path が**ディレクトリ**のときに限り request 時に stat して埋める
/// （最終レビュー Finding 1）。
///
/// なぜディレクトリだけか: file_mtime/file_size は dedup スキャン（DuplicateScanTask）でのみ
/// 書き込まれ、かつそのスキャンはディレクトリを skip する。そのため G9b archive モードの
/// フォルダブックは import 後ずっと両方 nil のままで、bookETag が "id-0-0-<pathhash>" に恒久固定
/// されてしまう（中身を差し替えても誰にも気付かれない＝本 Finding の核心）。
/// 一方、通常のアーカイブファイル本もインポート直後はまだ dedup スキャンが走っておらず
/// 両方 nil なことが普通にある。そこまで stat 対象にすると、rating/title だけの編集で
/// BookContentCache を invalidate しない既存の保証（BookContentCacheInvalidationTests）が、
/// 「未スキャンファイルの stat 値がリクエストごとに変わりうる」という別の変動要因に晒されて
/// 壊れてしまう。ディレクトリに限定することで、対象を「本当に恒久固定される行」だけに絞る。
///
/// stat が失敗（パス消失等）した場合は (nil, nil) を返し、呼び出し側で 0/0 にフォールバックする。
func effectiveFileStat(for row: BookRow) -> (mtime: Double?, size: Int64?) {
    if let mtime = row.fileMtime, let size = row.fileSize {
        return (mtime, size)
    }
    guard let path = row.path else { return (nil, nil) }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return (nil, nil)
    }
    let (statSize, statMtime) = Database.statFile(path)
    return (statMtime, statSize)
}

/// 本の原本ファイルの mtime+size+path から弱 ETag を作る（spec §3.3, G4d）。
/// path を織り込むことで、relink 直後に mtime/size が万一 nil でも etag が変わり、
/// また異なるパスの book が "id-0-0" で衝突しない。
/// fileMtime/fileSize は contentHash 計算時に記録される列で、未計算の本では 0 にフォールバックする
/// （ディレクトリの場合は effectiveFileStat が request 時 stat で埋める・Finding 1）。
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
