// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryStore

@Suite("library_settings I/O")
struct LibrarySettingsTests {
    @Test func getNonexistentReturnsNil() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let val = try db.getLibrarySetting(key: "doesNotExist")
        #expect(val == nil)
    }

    @Test func setAndGetRoundTrip() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.setLibrarySetting(key: "color", value: "blue")
        let val = try db.getLibrarySetting(key: "color")
        #expect(val == "blue")
    }

    @Test func setOverwrites() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.setLibrarySetting(key: "color", value: "blue")
        try db.setLibrarySetting(key: "color", value: "red")
        let val = try db.getLibrarySetting(key: "color")
        #expect(val == "red")
    }

    @Test func storesJSONLikeValues() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let json = #"["title","rating","author"]"#
        try db.setLibrarySetting(key: "listViewColumns", value: json)
        let got = try db.getLibrarySetting(key: "listViewColumns")
        #expect(got == json)
    }
}
