// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("AddBooks DTO")
struct AddBooksDTOTests {
    @Test func requestRoundTrip() throws {
        let req = AddBooksRequestDTO(paths: ["/a/b.cbz", "/a/c.zip"], presetID: "p1")
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(AddBooksRequestDTO.self, from: data)
        #expect(back.paths == ["/a/b.cbz", "/a/c.zip"])
        #expect(back.presetID == "p1")
    }
    @Test func replyRoundTrip() throws {
        let rep = AddBooksReplyDTO(addedIDs: [1, 2], alreadyPresent: ["/a/x.zip"], failed: [])
        let data = try JSONEncoder().encode(rep)
        let back = try JSONDecoder().decode(AddBooksReplyDTO.self, from: data)
        #expect(back.addedIDs == [1, 2])
        #expect(back.alreadyPresent == ["/a/x.zip"])
        #expect(back.failed.isEmpty)
    }
}
