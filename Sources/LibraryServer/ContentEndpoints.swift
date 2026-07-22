// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import LibraryStore
import AppCore
import Hummingbird
import LibraryServerAPI

/// row.path が**ディレクトリ**の場合は、保存済み file_mtime/file_size の有無にかかわらず
/// 常に request 時にディレクトリ自身を stat する。それ以外（ファイル・path なし）は、
/// file_mtime/file_size が両方揃っていればそのまま返し、揃っていなければ (nil, nil) を返す
/// （最終レビュー Finding 1 → 実機 smoke で発覚した再発防止の追加修正）。
///
/// なぜディレクトリは stored 値を無視するか: file_mtime/file_size は dedup スキャン
/// （DuplicateScanTask）でのみ書き込まれ、かつそのスキャンはディレクトリを skip する。
/// そのため G9b archive モードのフォルダブックは import 直後、両方 nil のままで、
/// 旧実装ではここで request 時 stat にフォールバックしていた。
/// ところが relinkBook/applyRelinks（G4d 層1・アーカイブファイル本向け）は path 更新のたびに
/// file_size/file_mtime を**無条件に**書き込む。フォルダブックが一度でも relink を経由すると
/// 両方 non-nil になり、以後は「両方揃っていればそのまま返す」旧ロジックの stored-value
/// ショートカットに恒久的に吸い込まれる。ディレクトリの mtime/size は relink 以降誰も更新しない
/// ため、そのフォルダブックの bookETag は relink 時点の値に凍りつき、直下に子ファイルを
/// 追加/削除/リネームしても二度と変化しない（実機 smoke で id=19 にて再現：manifest の
/// pageCount は BookContentFactory.make を毎回呼ぶので増えるが、pages/:n は凍りついた ETag を
/// basis にした BookContentCache から古い FolderBookContent を返し続け、新ページは 404 になる）。
/// ディレクトリという「本当に stored 値が信用できない」対象に限って常に request 時 stat を
/// 優先することで、relink 済みかどうかに関わらずフォルダブックの ETag が正しく追従するようにする。
/// ファイル本（アーカイブ）は stored 値が dedup スキャンで一度計算されれば以後不変で正しいため、
/// 従来どおり stored 値を優先し続ける（stat 値の churn で ETag が動くと全クライアントが
/// 再ダウンロードすることになるため、ここは変えてはいけない）。
///
/// ディレクトリの stat が失敗した場合（NAS の一時的な不調・権限喪失・削除との競合など）は、
/// (nil, nil) を返さず stored 値のフォールバックへ**落とす**。ここで (nil, nil) を返すと ETag が
/// "id-0-0-hash" に崩れ、一瞬の I/O 不調だけで全クライアントがそのフォルダブックのページ
/// キャッシュを丸ごと捨てて再ダウンロードし、復旧時にもう一度捨てることになる（レビュー Minor）。
/// path 自体が無い／ファイルで stored 値も無い場合は従来どおり (nil, nil)（呼び出し側で 0/0）。
func effectiveFileStat(for row: BookRow) -> (mtime: Double?, size: Int64?) {
    if let path = row.path {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            let (statSize, statMtime) = Database.statFile(path)
            if statMtime != nil || statSize != nil {
                return (statMtime, statSize)
            }
            // stat 失敗 → stored 値へフォールバック（下の分岐へ落ちる）
        }
    }
    if let mtime = row.fileMtime, let size = row.fileSize {
        return (mtime, size)
    }
    return (nil, nil)
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
/// （404/409 にはしない）が、誤った版キーの URL の下へは HTTP キャッシュにも
/// クライアントの IndexedDB 等アプリ内キャッシュにも一切残さない。
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
}
