// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import LibraryServerAPI

/// G23 (M2): DL 済みファイルの**先頭数バイトだけ**読んで拡張子を判定する。
/// ストリーミング化で本文が `Data` として手元に無くなったため、全量を読み直さずに済ませる。
/// 読めない場合は既定（zip）にフォールバックする（従来の magic 不一致時と同じ扱い）。
public func offlineFileExtension(forFileAt url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "zip" }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 4)) ?? Data()
    return offlineFileExtension(for: head)
}

/// G51 smoke 9.3: 保存名の拡張子。サーバが元ファイルの拡張子を返していれば（4.2c-6b で追加された
/// `BookDetailDTO.fileExtension`）それを使い、無い／不正なときだけ magic で推定する。
/// EPUB・CBZ は ZIP、RAR・7z は未知の magic なので、いずれも推定では `"zip"` に落ちる。
/// オフラインの EPUB が `<id>.zip` で保存され、開く側の拡張子判定に当たらなかったのがこの不具合。
public func offlineFileExtension(for detail: BookDetailDTO, fileAt url: URL) -> String {
    if let ext = detail.fileExtension?.lowercased(), OfflineStore.isValidFileExtension(ext) { return ext }
    return offlineFileExtension(forFileAt: url)
}

/// DL したファイルバイトから拡張子を magic で判定（detail.path はサーバが nil 化しているため）。
public func offlineFileExtension(for data: Data) -> String {
    let p = data.prefix(4)
    if p.starts(with: [0x50, 0x4B]) { return "zip" }
    if p.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
    if p.starts(with: [0xFF, 0xD8]) { return "jpg" }
    if p.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    return "zip"
}

/// DownloadedBook をローカルキャッシュパス付き BookRow に変換（オフライン再生・詳細ペイン用）。
public func offlineBookRow(_ book: DownloadedBook, fileURL: URL) -> BookRow {
    let d = book.detail
    let dir: PageDirection? = d.pageDirection == "rtl" ? .rightToLeft
                            : d.pageDirection == "ltr" ? .leftToRight
                            : nil
    return BookRow(
        id: d.id,
        title: d.title,
        author: d.author,
        genre: d.genre,
        path: fileURL.path,
        dateAdded: d.dateAdded,
        playDate: d.playDate,
        bookType: d.bookType,
        fileType: d.fileType,
        pages: d.pages,
        rating: d.rating,
        unseen: d.unseen,
        keywordA: d.keywordA,
        keywordB: d.keywordB,
        keywordC: d.keywordC,
        neta: d.neta,
        memo: d.memo,
        series: d.series,
        volume: d.volume,
        coverImageName: d.coverImageName,
        coverCropRect: BookRow.decodeCoverCropRect(json: d.coverCropRectJSON),
        pageDirection: dir,
        contentHash: nil,
        fileSize: nil,
        fileMtime: nil
    )
}
