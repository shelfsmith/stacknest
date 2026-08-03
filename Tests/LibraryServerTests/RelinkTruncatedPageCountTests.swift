// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
@testable import LibraryServer

/// G26 Codex Important #2: relink 先が破損していても、打ち切り読みから出たページ数は書かない。
///
/// relink は**まさに**ユーザーが差し替え先を指し示す操作なので、ここで 40 → 2 に縮めると
/// 「読了」に化けたうえで、次に開いたときのクランプ書き戻しで読書位置まで失われる
/// （`TruncatedReadPolicy` を作った事故と同じ経路）。書かなければ、修復後の次回オープンで
/// 収束処理が正しい値を入れる。
@Suite("POST /relink — 破損コピーのページ数を書かない (G26)")
struct RelinkTruncatedPageCountTests {

    private func makeApp(_ fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    private func relink(_ fixture: TestLibraryFixture, bookID: Int, to newPath: String) async throws {
        let lib = fixture.servedLibrary()
        let body = try JSONEncoder().encode(RelinkRequest(newPath: newPath))
        try await makeApp(fixture).test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .noContent) }
        }
    }

    /// 健全な差し替え先では従来どおり実ページ数に更新される（G21 #5 の回帰ガード）。
    /// このテストが無いと、下の「書かない」テストは「relink が何も書かなくなった」だけでも通る。
    @Test func relinkToHealthyCopyUpdatesPageCount() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkPagesOK", bookCount: 0)
        defer { fixture.cleanup() }
        let oldPath = fixture.bundleURL.appendingPathComponent("old.zip").path
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: oldPath, dateAdded: Date()))
        try fixture.db.updateBookPages(id: bookID, newPages: 40)
        let healthy = try fixture.copyFixtureZip(named: "three_pages")

        try await relink(fixture, bookID: bookID, to: healthy.path)

        #expect(try fixture.db.fetchBook(id: bookID)?.pages == 3)
    }

    /// 本命: 破損コピーへ relink しても、打ち切り読みのページ数（2）は書かれず旧値が残る。
    @Test func relinkToDamagedCopyKeepsTheOldPageCount() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkPagesDamaged", bookCount: 0)
        defer { fixture.cleanup() }
        let oldPath = fixture.bundleURL.appendingPathComponent("old.zip").path
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: oldPath, dateAdded: Date()))
        try fixture.db.updateBookPages(id: bookID, newPages: 40)
        let damaged = try fixture.copyFixtureZip(named: "damaged")

        try await relink(fixture, bookID: bookID, to: damaged.path)

        let after = try fixture.db.fetchBook(id: bookID)
        #expect(after?.path == damaged.path, "relink 自体は成功していること")
        #expect(after?.pages == 40,
                "打ち切り読みのページ数が書かれた（読了に化け、次回オープンで読書位置が壊れる）")
    }
}
