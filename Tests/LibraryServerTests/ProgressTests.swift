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
}
