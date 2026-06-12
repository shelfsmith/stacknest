// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Progress endpoint")
struct ProgressTests {
    @Test func postProgressUpdatesLastPage() async throws {
        let fixture = try TestLibraryFixture(name: "Pr", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": 12}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(try fixture.db.loadViewerState(bookID: 1).lastPage == 12)
    }

    /// 既存の viewer フラグ（spread/coverOffset）は progress 書き込みで壊れない。
    @Test func postProgressPreservesViewerFlags() async throws {
        let fixture = try TestLibraryFixture(name: "Pr3", bookCount: 1)
        defer { fixture.cleanup() }
        try fixture.db.saveViewerState(bookID: 1, spreadEnabled: true, coverOffset: false, lastPage: 2)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": 9}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        let state = try fixture.db.loadViewerState(bookID: 1)
        #expect(state.lastPage == 9)
        #expect(state.spreadEnabled == true)
        #expect(state.coverOffset == false)
    }

    @Test func negativePageIs400() async throws {
        let fixture = try TestLibraryFixture(name: "Pr2", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": -1}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        // DB は書き換わっていない
        #expect(try fixture.db.loadViewerState(bookID: 1).lastPage == 0)
    }

    /// 不明な book id → 404。
    @Test func unknownBookIs404() async throws {
        let fixture = try TestLibraryFixture(name: "Pr4", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/999/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": 1}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// progress 書き込みは mark-as-read（unseen=false ＋ play_date 設定）も行う（4.2a・Mac ビューワとパリティ）。
    @Test func postProgressMarksAsRead() async throws {
        let fixture = try TestLibraryFixture(name: "Pr5", bookCount: 1)
        defer { fixture.cleanup() }
        try fixture.db.setUnread(bookIDs: [1], unread: true)   // 明示的に未読へ
        #expect(try fixture.db.fetchBook(id: 1)?.unseen == true)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": 3}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        let row = try fixture.db.fetchBook(id: 1)
        #expect(row?.unseen == false)
        #expect(row?.playDate != nil)
    }

    /// progress 書き込みで onBookChanged が (uuid, bookID) で発火する（4.2a・Mac UI 即時反映の起点）。
    @Test func postProgressFiresOnBookChanged() async throws {
        let fixture = try TestLibraryFixture(name: "Pr6", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var calls: [(String, Int)] = []
        }
        let box = Box()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", onBookChanged: { uuid, id in
                box.lock.withLock { box.calls.append((uuid, id)) }
            }),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"page": 1}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        let calls = box.lock.withLock { box.calls }
        #expect(calls.count == 1)
        #expect(calls.first?.0 == lib.uuid)
        #expect(calls.first?.1 == 1)
    }
}
