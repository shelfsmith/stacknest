// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer
@testable import LibraryStore

@Suite("label-settings GET/PUT")
struct LabelSettingsEndpointTests {
    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }
    private func dec() -> JSONDecoder { JSONDecoder() }

    /// 未設定なら空マップで 200（R 可）。
    @Test func getReturnsEmptyWhenUnset() async throws {
        let fixture = try TestLibraryFixture(name: "Lbl1", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/label-settings",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try dec().decode(LabelSettingsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.customFieldLabels.isEmpty)
                #expect(dto.customBookTypeLabels.isEmpty)
            }
        }
    }

    /// PUT(RW) で保存 → GET で round-trip。
    @Test func putThenGetRoundTrips() async throws {
        let fixture = try TestLibraryFixture(name: "Lbl2", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/label-settings",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"customFieldLabels":{"keyword_c":"作者別名"},"customBookTypeLabels":{"0":"長編"}}"#)
            ) { resp in #expect(resp.status == .ok) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/label-settings",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                let dto = try dec().decode(LabelSettingsDTO.self, from: Data(buffer: resp.body))
                #expect(dto.customFieldLabels["keyword_c"] == "作者別名")
                #expect(dto.customBookTypeLabels["0"] == "長編")
            }
        }
    }

    /// PUT は RW 専用：R は 403。
    @Test func putRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "Lbl3", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/label-settings",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"customFieldLabels":{},"customBookTypeLabels":{}}"#)
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    /// PUT で onLibrarySettingsChanged が発火する。
    @Test func putFiresSettingsChanged() async throws {
        let fixture = try TestLibraryFixture(name: "Lbl4", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let changed = LabelChangeBox()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W",
                          onLibrarySettingsChanged: { uuid in changed.set(uuid) }),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/label-settings",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"customFieldLabels":{"genre":"作品種別"},"customBookTypeLabels":{}}"#)
            ) { resp in #expect(resp.status == .ok) }
        }
        #expect(changed.value == lib.uuid)
    }
}

/// 単純な Sendable ボックス（コールバック観測用）。
final class LabelChangeBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v: String?
    func set(_ v: String) { lock.lock(); _v = v; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return _v }
}
