// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryStore

@Suite("bookETag")
struct BookETagTests {
    private func row(id: Int, path: String, fileMtime: Double?, fileSize: Int64?) -> BookRow {
        BookRow(
            id: id, title: "Book \(id)", author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            fileSize: fileSize, fileMtime: fileMtime
        )
    }

    @Test func etagChangesWhenPathChangesEvenWithNullStats() {
        // mtime/size が両方 nil でも、path が違えば etag は変わる（null 衝突防止）。
        let a = row(id: 1, path: "/x/a.cbz", fileMtime: nil, fileSize: nil)
        let b = row(id: 1, path: "/x/b.cbz", fileMtime: nil, fileSize: nil)
        #expect(bookETag(for: a) != bookETag(for: b))
    }

    @Test func etagStableForSameContent() {
        let a = row(id: 1, path: "/x/a.cbz", fileMtime: 100, fileSize: 50)
        let b = row(id: 1, path: "/x/a.cbz", fileMtime: 100, fileSize: 50)
        #expect(bookETag(for: a) == bookETag(for: b))
    }
}
