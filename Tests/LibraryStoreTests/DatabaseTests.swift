// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Database open/close")
struct DatabaseOpenTests {
    @Test("Opens an in-memory database and reports it is open")
    func opensInMemory() throws {
        let db = try Database.openInMemory()
        #expect(db.isOpen)
        db.close()
        #expect(db.isOpen == false)
    }
}
