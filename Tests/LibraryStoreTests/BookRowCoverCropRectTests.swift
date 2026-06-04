// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BookRow coverCropRect")
struct BookRowCoverCropRectTests {
    @Test
    func nilByDefault() {
        let row = BookRow(
            id: 1, title: "t", author: nil, genre: nil, path: nil,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        )
        #expect(row.coverCropRect == nil)
    }

    @Test
    func decodesJSONToCGRect() throws {
        let json = #"{"x":0.25,"y":0.0,"w":0.5,"h":1.0}"#
        let rect = BookRow.decodeCoverCropRect(json: json)
        #expect(rect == CGRect(x: 0.25, y: 0.0, width: 0.5, height: 1.0))
    }

    @Test
    func encodesCGRectToJSON() throws {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let json = BookRow.encodeCoverCropRect(rect)
        let decoded = BookRow.decodeCoverCropRect(json: json)
        #expect(decoded == rect)
    }

    @Test
    func roundTripsNil() {
        #expect(BookRow.decodeCoverCropRect(json: nil) == nil)
        #expect(BookRow.decodeCoverCropRect(json: "") == nil)
        #expect(BookRow.decodeCoverCropRect(json: "garbage{not json") == nil)
    }
}
