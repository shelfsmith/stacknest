// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

@Suite("LibrarySettings load/save")
struct LibrarySettingsLoadSaveTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test @MainActor
    func defaultColumnsWhenNoSetting() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        let expected: Set<BookColumn> = [.title, .rating, .author, .genre, .dateAdded, .playDate]
        #expect(settings.listViewColumns == expected)
    }

    @Test @MainActor
    func toggleColumnPersistsAndReloads() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        settings.toggleColumn(.unseen)
        #expect(settings.listViewColumns.contains(.unseen))

        // Re-load
        let settings2 = try LibrarySettings(database: db)
        #expect(settings2.listViewColumns.contains(.unseen))
    }

    @Test @MainActor
    func toggleTitleNoOp() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        settings.toggleColumn(.title)
        #expect(settings.listViewColumns.contains(.title))
    }

    @Test @MainActor
    func sortPersistsAndReloads() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        settings.listViewSort = ColumnSort(column: .author, ascending: true)

        let settings2 = try LibrarySettings(database: db)
        #expect(settings2.listViewSort == ColumnSort(column: .author, ascending: true))
    }

    @Test @MainActor
    func listColumnOrderPersists() throws {
        let db = try setupDB()
        let s1 = try LibrarySettings(database: db)
        s1.listColumnOrder = [.title, .author, .rating, .genre]

        let s2 = try LibrarySettings(database: db)
        // The first 4 elements preserve the user's persisted order...
        #expect(Array(s2.listColumnOrder.prefix(4)) == [.title, .author, .rating, .genre])
        // ...and any BookColumn cases not in the persisted array are appended,
        // so newly-introduced columns become orderable when reorder UI ships.
        #expect(Set(s2.listColumnOrder) == Set(BookColumn.allCases))
    }

    @Test @MainActor
    func listColumnOrderAppendsNewlyAddedCases() throws {
        let db = try setupDB()
        // Simulate a persisted older version of the catalog that knows only 2 cases.
        let oldOrder: [BookColumn] = [.author, .title]
        let json = try JSONEncoder().encode(oldOrder)
        let str = String(decoding: json, as: UTF8.self)
        try db.setLibrarySetting(key: "listColumnOrder", value: str)

        let s = try LibrarySettings(database: db)
        // Persisted prefix is preserved verbatim.
        #expect(Array(s.listColumnOrder.prefix(2)) == [.author, .title])
        // All other cases are appended in BookColumn.allCases declaration order.
        #expect(s.listColumnOrder.count == BookColumn.allCases.count)
    }

    @Test @MainActor
    func filterStateDefaultIsEmpty() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        #expect(settings.filterState.isEmpty)
    }

    @Test @MainActor
    func filterStatePersistsAcrossInstances() throws {
        let db = try setupDB()
        let s1 = try LibrarySettings(database: db)
        var newFilter = FilterState()
        newFilter.bookTypes = [0, 2]
        newFilter.ratingMin = 3
        s1.filterState = newFilter

        let s2 = try LibrarySettings(database: db)
        #expect(s2.filterState == newFilter)
    }

    @Test @MainActor
    func filterStateDecodeFailureFallsBackToEmpty() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "filterState", value: "{ not valid json }")
        let settings = try LibrarySettings(database: db)
        #expect(settings.filterState.isEmpty)
    }

    @Test @MainActor
    func browserPaneStateDefaultIsDefault() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        let s = settings.browserPaneState
        #expect(s.fields == [.genre, .author, .keywordA])
        #expect(s.selections == [nil, nil, nil])
        #expect(s.height == 200)
    }

    @Test @MainActor
    func browserPaneStatePersistsAcrossInstances() throws {
        let db = try setupDB()
        let s1 = try LibrarySettings(database: db)
        var newState = BrowserPaneState()
        newState.fields = [.keywordB, .keywordC, nil]
        newState.selections = ["tag-b", "tag-c", nil]
        newState.height = 320
        s1.browserPaneState = newState

        let s2 = try LibrarySettings(database: db)
        #expect(s2.browserPaneState == newState)
    }

    @Test @MainActor
    func browserPaneStateDecodeFailureFallsBackToDefault() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "browserPaneState", value: "{ not valid json }")
        let settings = try LibrarySettings(database: db)
        #expect(settings.browserPaneState.fields == [.genre, .author, .keywordA])
        #expect(settings.browserPaneState.selections == [nil, nil, nil])
        #expect(settings.browserPaneState.height == 200)
    }

    @Test @MainActor
    func windowFrameDefaultIsNil() throws {
        let db = try setupDB()
        let settings = try LibrarySettings(database: db)
        #expect(settings.windowFrame == nil)
    }

    @Test @MainActor
    func windowFramePersistsAcrossInstances() throws {
        let db = try setupDB()
        let s1 = try LibrarySettings(database: db)
        let newFrame = WindowFrame(x: 100, y: 200, width: 800, height: 600)
        s1.windowFrame = newFrame
        // G36 ③: windowFrame の書き込みはデバウンスされる（ドラッグ中ずっと発火するため）。
        // 別インスタンスで読む前に flush しないと、まだディスクに届いていない可能性がある。
        s1.flushPendingWrites()

        let s2 = try LibrarySettings(database: db)
        #expect(s2.windowFrame == newFrame)
    }

    @Test @MainActor
    func windowFrameCanBeUpdated() throws {
        let db = try setupDB()
        let s1 = try LibrarySettings(database: db)
        let frame1 = WindowFrame(x: 100, y: 200, width: 800, height: 600)
        s1.windowFrame = frame1
        // G36 ③: 書き込みはデバウンスされるので、次のインスタンスで読む前に確定させる。
        s1.flushPendingWrites()

        let s2 = try LibrarySettings(database: db)
        #expect(s2.windowFrame == frame1)

        // Update to a different frame
        let frame2 = WindowFrame(x: 50, y: 50, width: 1024, height: 768)
        s2.windowFrame = frame2
        // 更新後もう一度 flush してから読み直す。
        s2.flushPendingWrites()

        let s3 = try LibrarySettings(database: db)
        #expect(s3.windowFrame == frame2)
    }

    @Test @MainActor
    func windowFrameDecodeFailureFallsBackToNil() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "windowFrame", value: "{ not valid json }")
        let settings = try LibrarySettings(database: db)
        #expect(settings.windowFrame == nil)
    }
}
