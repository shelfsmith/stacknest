// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("SyntheticLibrary.generate")
struct SyntheticLibraryTests {
    private func freshDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test func insertsExactCount() throws {
        let db = try freshDB()
        try SyntheticLibrary.generate(into: db, count: 200)
        #expect(try db.fetchAllBooks().count == 200)
    }
    @Test func deterministicForSameSeed() throws {
        let a = try freshDB(); try SyntheticLibrary.generate(into: a, count: 50, seed: 7)
        let b = try freshDB(); try SyntheticLibrary.generate(into: b, count: 50, seed: 7)
        #expect(try a.fetchAllBooks().map(\.title) == b.fetchAllBooks().map(\.title))
    }
    @Test func ftsFindsSyntheticData() throws {
        let db = try freshDB()
        try SyntheticLibrary.generate(into: db, count: 100)
        let hits = try db.searchBooks(query: "シリーズ", sidebarScope: .library)
        #expect(!hits.isEmpty)
    }
}
