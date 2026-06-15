// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

@Suite struct FetchBooksFieldsTests {
    @Test func fieldsQueryItemSortedJoined() {
        let item = RemoteLibraryClient.fieldsQueryItem(["memo", "genre"])
        #expect(item?.name == "fields")
        #expect(item?.value == "genre,memo")
    }
    @Test func fieldsQueryItemNilWhenEmpty() {
        #expect(RemoteLibraryClient.fieldsQueryItem([]) == nil)
    }
}
