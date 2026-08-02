// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// `FilterState` は CLI/MCP から**部分的な JSON** で送られてくる。
/// synthesized Codable は非 Optional な `Set` 8 個すべての存在を要求するため、
/// 部分 JSON はデコードに失敗し、サーバ側で**黙って空フィルタに落ちていた**
/// （＝フィルタ指定が無視される。2026-08-01 に自走 smoke で発見）。
struct FilterStateDecodingTests {
    static func decode(_ json: String) throws -> FilterState {
        try JSONDecoder().decode(FilterState.self, from: Data(json.utf8))
    }

    @Test func partialJSONKeepsDefaultsForMissingKeys() throws {
        let fs = try Self.decode(#"{"unseen":0}"#)
        #expect(fs.unseen == .unreadOnly)
        #expect(fs.bookTypes.isEmpty)
        #expect(fs.genres.isEmpty)
        #expect(fs.ratingMin == nil)
        #expect(fs.isEmpty == false)     // unseen が効いている
    }

    @Test func emptyObjectDecodesToEmptyFilter() throws {
        let fs = try Self.decode("{}")
        #expect(fs.isEmpty)
    }

    @Test func fullJSONStillRoundTrips() throws {
        var fs = FilterState()
        fs.unseen = .readOnly
        fs.ratingMin = 3
        fs.genres = ["A", "B"]
        fs.dateAdded = .init(direction: .within, days: 7)
        let data = try JSONEncoder().encode(fs)
        let back = try JSONDecoder().decode(FilterState.self, from: data)
        #expect(back == fs)
    }

    @Test func malformedJSONThrows() throws {
        #expect(throws: (any Error).self) { _ = try Self.decode("not json") }
    }
}
