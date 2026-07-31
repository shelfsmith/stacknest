import Testing
import Foundation
@testable import LibraryServerAPI

/// BookListItemDTO の wire 形式（HTTP API の外形）を固定するゴールデンテスト。
///
/// このテストの目的は「フィールドの有無・キー名・型・null 表現が一切変わらないこと」を機械で保証すること。
/// リモートクライアントがこの JSON をデコードするため、ここが変わるとリモート閲覧が壊れる。
/// **期待値は実際にエンコーダを走らせた出力を貼ったもの（想像で書いたものではない）。**
/// エンコーダ設定はサーバ（LibraryServerCore の `.iso8601`）に合わせ、キー順安定のため `.sortedKeys` を付ける。
///
/// 注意: Optional は synthesized Codable の `encodeIfPresent` により **nil のときキーごと省略される**
/// （`"key":null` ではない）。`nilOptionalsOmitKeys` がその挙動を固定している。
@Suite struct BookListItemDTOWireFormatTests {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func json(_ dto: BookListItemDTO) throws -> String {
        String(decoding: try encoder().encode(dto), as: UTF8.self)
    }

    /// 全フィールドを埋めた基準 DTO。
    private var full: BookListItemDTO {
        BookListItemDTO(
            id: 42, title: "T", author: "A", series: "S", volume: 3.5,
            rating: 4, unseen: true, bookType: 1, pages: 120, lastPage: 7,
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_000),
            dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            hasCover: true, coverVersion: "cv1",
            genre: "G", neta: "N", keywordA: "KA", keywordB: "KB", keywordC: "KC", memo: "M",
            coverCropRectJSON: "{\"x\":0.25}", filename: "book.zip")
    }

    @Test func fullyPopulatedWireFormat() throws {
        #expect(try json(full) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
    }

    /// Optional が nil のときはキーが **省略される**（`null` を出さない）ことを固定する。
    @Test func nilOptionalsOmitKeys() throws {
        let empty = BookListItemDTO(
            id: 1, title: "", author: nil, series: nil, volume: nil,
            rating: 0, unseen: false, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0),
            hasCover: false, coverVersion: nil)
        #expect(try json(empty) == #"{"bookType":0,"dateAdded":"1970-01-01T00:00:00Z","hasCover":false,"id":1,"rating":0,"title":"","unseen":false}"#)
    }

    @Test func withCoverVersionWireFormat() throws {
        #expect(try json(full.withCoverVersion("cv2")) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv2","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
        // nil を渡すと coverVersion キーごと消える
        #expect(try json(full.withCoverVersion(nil)) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
    }

    @Test func keepingExtrasWireFormat() throws {
        // fields に含まれない動的フィールド（neta / keywordA-C）はキーごと消える
        #expect(try json(full.keepingExtras(["genre", "memo"])) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
        #expect(try json(full.keepingExtras([])) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","hasCover":true,"id":42,"lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
    }

    /// keepingExtras は memo を 200 字に切り詰める。
    @Test func keepingExtrasTruncatesMemo() {
        let long = BookListItemDTO(
            id: 42, title: "T", author: nil, series: nil, volume: nil,
            rating: 0, unseen: false, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0),
            hasCover: false, coverVersion: nil, memo: String(repeating: "x", count: 250))
        #expect(long.keepingExtras(["memo"]).memo?.count == 200)
    }

    @Test func withLastPageWireFormat() throws {
        #expect(try json(full.withLastPage(99)) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":99,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
        #expect(try json(full.withLastPage(nil)) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
    }

    @Test func withUnseenWireFormat() throws {
        #expect(try json(full.withUnseen(false)) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"lastReadAt":"2023-11-14T22:13:20Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":false,"volume":3.5}"#)
    }

    @Test func withLastReadAtWireFormat() throws {
        #expect(try json(full.withLastReadAt(Date(timeIntervalSince1970: 1_750_000_000))) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"lastReadAt":"2025-06-15T15:06:40Z","memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
        #expect(try json(full.withLastReadAt(nil)) == #"{"author":"A","bookType":1,"coverCropRectJSON":"{\"x\":0.25}","coverVersion":"cv1","dateAdded":"2020-09-13T12:26:40Z","filename":"book.zip","genre":"G","hasCover":true,"id":42,"keywordA":"KA","keywordB":"KB","keywordC":"KC","lastPage":7,"memo":"M","neta":"N","pages":120,"rating":4,"series":"S","title":"T","unseen":true,"volume":3.5}"#)
    }
}
