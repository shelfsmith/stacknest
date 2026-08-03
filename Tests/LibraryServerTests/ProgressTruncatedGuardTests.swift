// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryStore
import StackroomFormat
@testable import LibraryServer

/// G26 Codex Important #1: **Web リーダー経由でも**打ち切り読みから出た読書位置を DB へ書かない。
///
/// 再現していた事故（ネイティブ側で `TruncatedReadPolicy` を作った原因そのもの）:
/// 150 ページ中 30 ページしか読めない破損アーカイブを開く → リーダーの
/// `startUi = min(pageCount, p)` が保存済み位置を 29 へクランプ → その 29 が
/// `/progress` へ POST され、サーバが**無条件に**書いていた。ライブラリ上は「30/30＝読了」に
/// 化け、ファイルを直しても元の位置は戻らない。
///
/// 判定は必ずサーバで行う（クライアントの自己抑制には頼らない）。旧クライアントも
/// damageNote を知らないクライアントも居るため。
///
/// fixture: `Fixtures/damaged.zip` は 1x1 PNG 6 件の無圧縮 zip の 3 件目のローカルヘッダ署名を
/// 壊したもの（`Tests/AppCoreTests/DamagedZipFixture.makeDamagedZip()` と同一バイト列）。
/// libarchive はそこで ARCHIVE_FATAL を返すため、読めるのは 2 ページで truncated=true になる。
@Suite("POST /progress — 破損本の読書位置保護 (G26)")
struct ProgressTruncatedGuardTests {

    private func makeApp(_ fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    private func postProgress(_ fixture: TestLibraryFixture, bookID: Int, body: String,
                              expect status: HTTPResponse.Status = .ok) async throws {
        let lib = fixture.servedLibrary()
        try await makeApp(fixture).test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/progress", method: .post,
                headers: [.authorization: "Bearer tk", .contentType: "application/json"],
                body: .init(string: body)
            ) { response in
                #expect(response.status == status)
            }
        }
    }

    /// 前提の確認（このスイート全体の土台）: fixture が本当に「部分読み」として見えていること。
    /// これが崩れると以下のテストは全部 vacuous に通ってしまう。
    @Test func damagedFixtureIsReportedAsTruncatedByManifest() async throws {
        let fixture = try TestLibraryFixture(name: "PgT0", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
        let lib = fixture.servedLibrary()
        try await makeApp(fixture).test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                let text = String(buffer: response.body)
                #expect(text.contains("damageNote"), "破損 fixture が truncated として見えていない: \(text)")
                #expect(text.contains("\"pageCount\":2"), "読めるページ数が想定と違う: \(text)")
            }
        }
    }

    /// 本命: 破損本でクランプされた後退位置を POST しても、保存済み位置は動かない。
    @Test func clampedBackwardWriteOnDamagedBookIsIgnored() async throws {
        let fixture = try TestLibraryFixture(name: "PgT1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
        // 「読める 2 ページよりずっと先まで読んでいた」状態を作る。
        try fixture.db.updateLastPage(bookID: bookID, lastPage: 5)

        // リーダーは min(pageCount=2, …) → 末尾 apiIndex 1 にクランプしてこれを送ってくる。
        try await postProgress(fixture, bookID: bookID, body: #"{"page": 1}"#)

        #expect(try fixture.db.loadViewerState(bookID: bookID).lastPage == 5,
                "破損読みのクランプ位置が書き戻された（読書位置が破壊された）")
    }

    /// 破損本でも**前進**は従来どおり書ける（保護しすぎていないことの確認）。
    @Test func forwardWriteOnDamagedBookStillPersists() async throws {
        let fixture = try TestLibraryFixture(name: "PgT2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
        try fixture.db.updateLastPage(bookID: bookID, lastPage: 0)

        try await postProgress(fixture, bookID: bookID, body: #"{"page": 1}"#)

        #expect(try fixture.db.loadViewerState(bookID: bookID).lastPage == 1)
    }

    /// 破損していない本では後退書き込みも従来どおり通る（回帰ガード）。
    /// ここが壊れると「読み返して閉じたら位置が戻らない」という別の不具合になる。
    @Test func backwardWriteOnHealthyBookStillPersists() async throws {
        let fixture = try TestLibraryFixture(name: "PgT3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        try fixture.db.updateLastPage(bookID: bookID, lastPage: 2)

        try await postProgress(fixture, bookID: bookID, body: #"{"page": 0}"#)

        #expect(try fixture.db.loadViewerState(bookID: bookID).lastPage == 0)
    }

    /// 明示の「最初から」（restart: true）は破損本でも保存位置を捨てて 0 を書ける。
    /// ネイティブの resume シートが `storedLastPage = 0` にして意思を通すのと同じ経路。
    @Test func explicitRestartOverridesTheGuardOnDamagedBook() async throws {
        let fixture = try TestLibraryFixture(name: "PgT4", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
        try fixture.db.updateLastPage(bookID: bookID, lastPage: 5)

        try await postProgress(fixture, bookID: bookID, body: #"{"page": 0, "restart": true}"#)

        #expect(try fixture.db.loadViewerState(bookID: bookID).lastPage == 0,
                "明示の「最初から」が握り潰された（破損本を最初から読み直せない）")
    }

    /// `restart: false` を明示した場合と、キーを省略した旧クライアントは同じ扱い（保護される）。
    /// page==0 から意思を推測しないことの裏取りでもある — 0 は単に 1 ページ目でもあるため、
    /// 推測していると破損本の 1 ページ目を表示しただけで保存位置が消える。
    @Test func restartFalseAndOmittedKeyBothKeepTheGuard() async throws {
        for body in [#"{"page": 0, "restart": false}"#, #"{"page": 0}"#] {
            let fixture = try TestLibraryFixture(name: "PgT5", bookCount: 0)
            defer { fixture.cleanup() }
            let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
            try fixture.db.updateLastPage(bookID: bookID, lastPage: 5)

            try await postProgress(fixture, bookID: bookID, body: body)

            #expect(try fixture.db.loadViewerState(bookID: bookID).lastPage == 5,
                    "body=\(body) で保護が外れた")
        }
    }

    /// 書き込みを無視した場合でも mark-as-read（unseen=false / play_date）は従来どおり行う。
    /// 「開いた」という事実自体は打ち切りと無関係なので、ここまで止めると別の回帰になる。
    @Test func guardedWriteStillMarksAsRead() async throws {
        let fixture = try TestLibraryFixture(name: "PgT6", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "damaged")
        try fixture.db.updateLastPage(bookID: bookID, lastPage: 5)
        try fixture.db.setUnread(bookIDs: [bookID], unread: true)

        try await postProgress(fixture, bookID: bookID, body: #"{"page": 1}"#)

        let row = try fixture.db.fetchBook(id: bookID)
        #expect(row?.unseen == false)
        #expect(row?.playDate != nil)
    }
}
