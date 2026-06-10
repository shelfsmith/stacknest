// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

@Suite("LibraryServerDataSource")
struct DataSourceTests {
    @Test func staticDataSourceListsLibraries() async throws {
        let fixture = try TestLibraryFixture(name: "テスト棚", bookCount: 3)
        defer { fixture.cleanup() }
        let ds = StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        let libs = await ds.servedLibraries()
        #expect(libs.count == 1)
        #expect(libs[0].name == "テスト棚")
        #expect(libs[0].isLocked == false)
        #expect(!libs[0].uuid.isEmpty)
    }

    @Test func lockedFixtureReportsLockedAndVerifiesPassword() async throws {
        let fixture = try TestLibraryFixture(name: "鍵棚", bookCount: 1, locked: true, password: "pw123")
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        #expect(lib.isLocked)
        #expect(lib.verifyPassword("pw123"))
        #expect(!lib.verifyPassword("wrong"))
    }
}
