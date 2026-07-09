// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer
import LibraryServerAPI

/// G8a Task 3: mutation エンドポイントが EventHub へ publish すること（progress は除外）を検証する。
@Suite("Live-sync publish wiring")
struct LiveSyncPublishTests {

    private func makeCoreAndApp(_ lib: ServedLibrary, editToken: String? = "W") -> (LibraryServerCore, some ApplicationProtocol) {
        let core = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        )
        return (core, core.buildApplication())
    }

    /// rating（本を mutate する通常エンドポイント）→ .bookChanged が publish される。
    /// progress（4.2a・高頻度エンドポイント）→ 意図的に EventHub へは流さない。
    @Test func ratingPublishesButProgressDoesNot() async throws {
        let fixture = try TestLibraryFixture(name: "LiveSync1", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let (core, app) = makeCoreAndApp(lib)
        let sub = await core.eventHub.subscribe(scope: .all)
        let stream = sub.stream

        try await app.test(.router) { client in
            // イテレータは Sendable ではないため、並行実行される client クロージャの内側で
            // ローカルに生成する（外側の var を跨いで捕まえると Swift 6 の
            // #SendableClosureCaptures で弾かれる）。
            var it = stream.makeAsyncIterator()
            // rating → bookChanged が publish される。
            _ = try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/rating", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(#"{"rating":3}"#.utf8))
            ) { _ in }
            #expect(await it.next() == .bookChanged(library: lib.uuid, bookID: 1))

            // progress → publish されない（onBookChanged コールバックのみ・EventHub へは流さない）。
            _ = try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(#"{"page":2}"#.utf8))
            ) { _ in }

            // progress 後、新イベントが来ないこと（unsubscribe → stream 終了 → next() == nil で締める）。
            await core.eventHub.unsubscribe(sub.id)
            #expect(await it.next() == nil)
        }
    }
}
