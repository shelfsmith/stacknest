// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackroomFormat
@testable import LibraryServerAPI

@Suite("Shelf request DTOs")
struct ShelfDTOCodableTests {
    @Test func createRequestRoundTrips() throws {
        let cond = SmartShelfConditions(version: 1, match: .all, rules: [])
        let req = ShelfCreateRequest(title: "棚", isSmart: true, conditions: cond)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(ShelfCreateRequest.self, from: data)
        #expect(back.title == "棚")
        #expect(back.isSmart == true)
        #expect(back.conditions?.match == .all)
    }
    @Test func booksRequestDecodes() throws {
        let data = Data(#"{"bookIDs":[1,2,3]}"#.utf8)
        let req = try JSONDecoder().decode(ShelfBooksRequest.self, from: data)
        #expect(req.bookIDs == [1, 2, 3])
    }
}
