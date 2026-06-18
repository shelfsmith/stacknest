import Testing
import Foundation
@testable import LibraryServerAPI

@Suite struct BookListItemDTOTests {
    private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    @Test func roundTripWithExtras() throws {
        let dto = BookListItemDTO(
            id: 1, title: "T", author: "A", series: "S", volume: 2,
            rating: 3, unseen: true, bookType: 1, pages: 10, lastPage: 5,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0), hasCover: false, coverVersion: nil,
            genre: "G", neta: "N", keywordA: "KA", keywordB: "KB", memo: "M")
        let data = try enc().encode(dto)
        let back = try dec().decode(BookListItemDTO.self, from: data)
        #expect(back.genre == "G")
        #expect(back.neta == "N")
        #expect(back.keywordA == "KA")
        #expect(back.keywordB == "KB")
        #expect(back.memo == "M")
    }

    @Test func decodesWhenExtrasMissing() throws {
        let json = """
        {"id":1,"title":"T","author":null,"series":null,"volume":null,"rating":0,
         "unseen":false,"bookType":0,"pages":null,"lastPage":null,"lastReadAt":null,
         "dateAdded":"1970-01-01T00:00:00Z","hasCover":false,"coverVersion":null}
        """
        let back = try dec().decode(BookListItemDTO.self, from: Data(json.utf8))
        #expect(back.genre == nil)
        #expect(back.memo == nil)
    }

    @Test func extraFieldsOmittedWhenNil() throws {
        let dto = BookListItemDTO(
            id: 1, title: "T", author: nil, series: nil, volume: nil,
            rating: 0, unseen: false, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0), hasCover: false, coverVersion: nil)
        let json = String(data: try enc().encode(dto), encoding: .utf8)!
        #expect(!json.contains("\"genre\""))
        #expect(!json.contains("\"memo\""))
    }

    @Test func withUnseenReplacesFlag() {
        let dto = BookListItemDTO(
            id: 1, title: "T", author: nil, series: nil, volume: nil,
            rating: 0, unseen: true, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0), hasCover: false, coverVersion: nil,
            genre: "G")
        let s = dto.withUnseen(false)
        #expect(s.unseen == false)
        #expect(s.genre == "G")
        #expect(s.id == 1)
    }

    @Test func withLastReadAtReplaces() {
        let dto = BookListItemDTO(
            id: 1, title: "T", author: nil, series: nil, volume: nil,
            rating: 0, unseen: false, bookType: 0, pages: nil, lastPage: nil,
            lastReadAt: nil, dateAdded: Date(timeIntervalSince1970: 0), hasCover: false, coverVersion: nil,
            genre: "G")
        let d = Date(timeIntervalSince1970: 1000)
        let s = dto.withLastReadAt(d)
        #expect(s.lastReadAt == d)
        #expect(s.genre == "G")
        #expect(s.id == 1)
    }
}
