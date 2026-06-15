import Testing
@testable import AppCore

@Suite struct RemoteListMappingTests {
    @Test func serverSortKeyCoversAllColumns() {
        #expect(BookColumn.title.serverSortKey == "title")
        #expect(BookColumn.rating.serverSortKey == "rating")
        #expect(BookColumn.author.serverSortKey == "author")
        #expect(BookColumn.genre.serverSortKey == "genre")
        #expect(BookColumn.dateAdded.serverSortKey == "dateAdded")
        #expect(BookColumn.playDate.serverSortKey == "lastRead")
        #expect(BookColumn.unseen.serverSortKey == "unseen")
        #expect(BookColumn.bookType.serverSortKey == "bookType")
        #expect(BookColumn.neta.serverSortKey == "neta")
        #expect(BookColumn.keywordA.serverSortKey == "keywordA")
        #expect(BookColumn.keywordB.serverSortKey == "keywordB")
        #expect(BookColumn.memo.serverSortKey == "memo")
        #expect(BookColumn.series.serverSortKey == "series")
        #expect(BookColumn.volume.serverSortKey == "volume")
    }

    @Test func wireFieldOnlyForOptionalExtras() {
        #expect(BookColumn.genre.wireField == "genre")
        #expect(BookColumn.neta.wireField == "neta")
        #expect(BookColumn.keywordA.wireField == "keywordA")
        #expect(BookColumn.keywordB.wireField == "keywordB")
        #expect(BookColumn.memo.wireField == "memo")
        #expect(BookColumn.title.wireField == nil)
        #expect(BookColumn.rating.wireField == nil)
        #expect(BookColumn.author.wireField == nil)
        #expect(BookColumn.dateAdded.wireField == nil)
        #expect(BookColumn.playDate.wireField == nil)
        #expect(BookColumn.unseen.wireField == nil)
        #expect(BookColumn.bookType.wireField == nil)
        #expect(BookColumn.series.wireField == nil)
        #expect(BookColumn.volume.wireField == nil)
    }

    @Test func fieldsForVisibleColumns() {
        let cols: Set<BookColumn> = [.title, .author, .genre, .memo]
        #expect(RemoteListFields.fields(for: cols) == Set(["genre", "memo"]))
        #expect(RemoteListFields.fields(for: [.title, .author]) == Set<String>())
    }
}
