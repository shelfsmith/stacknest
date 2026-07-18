// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("DTO JSON round-trip（共有 wire 契約）")
struct DTORoundTripTests {
    private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    @Test func bookPageRoundTrip() throws {
        let item = BookListItemDTO(
            id: 7, title: "T", author: "A", series: "S", volume: 2,
            rating: 3, unseen: true, bookType: 0, pages: 20, lastPage: 5,
            lastReadAt: Date(timeIntervalSince1970: 1_000_000), dateAdded: Date(timeIntervalSince1970: 0),
            hasCover: true, coverVersion: "v1")
        let page = BookPageDTO(items: [item], total: 1, page: 1, perPage: 100)
        let back = try dec().decode(BookPageDTO.self, from: enc().encode(page))
        #expect(back.total == 1)
        #expect(back.items.first?.id == 7)
        #expect(back.items.first?.lastPage == 5)
        #expect(back.items.first?.coverVersion == "v1")
    }

    @Test func manifestRoundTrip() throws {
        let m = ManifestDTO(pageCount: 12, direction: "rtl", format: "archive", etag: "e1")
        let back = try dec().decode(ManifestDTO.self, from: enc().encode(m))
        #expect(back.pageCount == 12)
        #expect(back.direction == "rtl")
        #expect(back.pageOverrides == nil)
    }

    /// G17 T6b: pageOverrides ありの往復＋旧クライアント互換（キー無し JSON も decode できる）。
    @Test func manifestPageOverridesRoundTripAndBackwardCompat() throws {
        let m = ManifestDTO(pageCount: 5, direction: "ltr", format: "archive", etag: "e2", pageOverrides: ["2": 1, "4": 0])
        let back = try dec().decode(ManifestDTO.self, from: enc().encode(m))
        #expect(back.pageOverrides == ["2": 1, "4": 0])

        // pageOverrides キー自体が無い旧サーバ形式の JSON でも decode できる（後方互換）。
        let legacyJSON = #"{"pageCount":5,"direction":"ltr","format":"archive","etag":"e2"}"#
        let legacy = try dec().decode(ManifestDTO.self, from: Data(legacyJSON.utf8))
        #expect(legacy.pageOverrides == nil)
        #expect(legacy.pageCount == 5)
    }

    @Test func libraryAndCapsRoundTrip() throws {
        let lib = LibraryDTO(id: "u", name: "N", locked: true, bookCount: 9)
        #expect(try dec().decode(LibraryDTO.self, from: enc().encode(lib)).locked == true)
        let caps = ServerCapabilities.inApp
        #expect(try dec().decode(ServerCapabilities.self, from: enc().encode(caps)).version == "1")
        let reply = UnlockReply(libraryToken: "tok")
        #expect(try dec().decode(UnlockReply.self, from: enc().encode(reply)).libraryToken == "tok")
    }

    @Test func shelfAndBrowseConstraintRoundTrip() throws {
        let s = ShelfDTO(id: 5, title: "棚", kind: "user", isSmart: false)
        #expect(try dec().decode(ShelfDTO.self, from: enc().encode(s)).title == "棚")
        let bc = BrowseConstraint(column: "genre", value: "SF")
        #expect(try dec().decode(BrowseConstraint.self, from: enc().encode(bc)).value == "SF")
    }
    @Test func bookDetailRoundTrip() throws {
        let d = BookDetailDTO(
            id: 9, title: "T", author: "A", genre: "G", path: "/p", dateAdded: Date(timeIntervalSince1970: 0),
            playDate: nil, bookType: 0, fileType: 2, pages: 12, rating: 3, unseen: true,
            keywordA: "ka", keywordB: nil, keywordC: nil, neta: "n", memo: "m", series: "S", volume: 2,
            coverImageName: nil, coverCropRectJSON: nil, pageDirection: "rtl")
        let back = try dec().decode(BookDetailDTO.self, from: enc().encode(d))
        #expect(back.keywordA == "ka")
        #expect(back.pageDirection == "rtl")
    }
}
