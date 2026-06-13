// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import LibraryServerAPI

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
