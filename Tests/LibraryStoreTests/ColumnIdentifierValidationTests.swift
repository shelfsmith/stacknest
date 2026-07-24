// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// #16 (LOW / defense-in-depth): SQL カラム識別子は bind パラメータ化できず文字列補間する
/// しかないため、補間前に許可リストで検証する `Database.validatedColumn(_:allowed:)` を
/// ユニットテストする。値ではなく識別子そのものへの injection-y な入力を拒否できることを確認する。
@Suite("Database.validatedColumn")
struct ColumnIdentifierValidationTests {
    private let allowed: Set<String> = [
        "genre", "series", "author", "neta", "keyword_a", "keyword_b", "keyword_c",
        "rating", "book_type",
    ]

    @Test func acceptsEachAllowedColumn() throws {
        for column in allowed {
            let validated = try Database.validatedColumn(column, allowed: allowed)
            #expect(validated == column)
        }
    }

    @Test func rejectsUnknownColumn() {
        #expect(throws: DatabaseError.self) {
            _ = try Database.validatedColumn("totally_unknown", allowed: allowed)
        }
    }

    @Test func rejectsSQLInjectionAttemptViaSuffix() {
        #expect(throws: DatabaseError.self) {
            _ = try Database.validatedColumn("id AS x; DROP TABLE book", allowed: allowed)
        }
    }

    @Test func rejectsCommentInjectionAttempt() {
        #expect(throws: DatabaseError.self) {
            _ = try Database.validatedColumn("genre--", allowed: allowed)
        }
    }

    @Test func rejectsQualifiedColumnNotInAllowlist() {
        // "b.title" は browse 許可リストに含まれないカラム（多値対象外）を qualified 名で狙うケース。
        #expect(throws: DatabaseError.self) {
            _ = try Database.validatedColumn("b.title", allowed: allowed)
        }
    }

    @Test func rejectsCaseVariantOfAllowedColumn() {
        // 大文字小文字違いは許可リストに厳密一致しないため拒否される（許可リストの意図しない拡大防止）。
        #expect(throws: DatabaseError.self) {
            _ = try Database.validatedColumn("GENRE", allowed: allowed)
        }
    }

    // MARK: - Integration through the public boundary (distinctValues / searchBooks)

    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test func distinctValuesRejectsUnknownColumn() throws {
        let db = try setupDB()
        #expect(throws: DatabaseError.self) {
            _ = try db.distinctValues(forColumn: "id AS x; DROP TABLE book", query: "", sidebarScope: .library)
        }
    }

    @Test func distinctValuesAcceptsKnownColumn() throws {
        let db = try setupDB()
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values.isEmpty)
    }

    @Test func searchBooksRejectsUnknownBrowserConstraintColumn() throws {
        let db = try setupDB()
        #expect(throws: DatabaseError.self) {
            _ = try db.searchBooks(
                query: "",
                sidebarScope: .library,
                browserConstraints: [("title--", "x")]
            )
        }
    }
}
