// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryStore

@Suite("LibraryStore module presence")
struct LibraryStoreModulePresenceTests {
    @Test("Module exposes a versioned identifier")
    func moduleHasVersion() {
        #expect(LibraryStore.moduleVersion == "0.1.0")
    }

    @Test("Database type is reachable")
    func databaseTypeReachable() throws {
        let db = try Database.openInMemory()
        #expect(db.isOpen)
        db.close()
    }
}
