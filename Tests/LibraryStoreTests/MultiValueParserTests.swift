// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("MultiValueParser")
struct MultiValueParserTests {
    @Test
    func splitSingleValue() throws {
        #expect(MultiValueParser.split("マンガ") == ["マンガ"])
    }

    @Test
    func splitMultipleValues() throws {
        #expect(MultiValueParser.split("マンガ, 小説") == ["マンガ", "小説"])
    }

    @Test
    func splitTrimsWhitespace() throws {
        #expect(MultiValueParser.split("マンガ ,  小説 , 画集") == ["マンガ", "小説", "画集"])
    }

    @Test
    func splitFiltersEmpty() throws {
        #expect(MultiValueParser.split(",, , マンガ,") == ["マンガ"])
    }

    @Test
    func splitEmptyOrWhitespace() throws {
        #expect(MultiValueParser.split("") == [])
        #expect(MultiValueParser.split("   ") == [])
    }

    @Test
    func joinSingle() throws {
        #expect(MultiValueParser.join(["マンガ"]) == "マンガ")
    }

    @Test
    func joinMultiple() throws {
        #expect(MultiValueParser.join(["マンガ", "小説"]) == "マンガ, 小説")
    }

    @Test
    func joinEmpty() throws {
        #expect(MultiValueParser.join([]) == "")
    }

    @Test
    func appendNewValue() throws {
        let result = MultiValueParser.append(to: "マンガ", value: "小説")
        #expect(result.0 == "マンガ, 小説")
        #expect(result.1 == true)
    }

    @Test
    func appendDuplicateSkips() throws {
        let result = MultiValueParser.append(to: "マンガ, 小説", value: "マンガ")
        #expect(result.0 == "マンガ, 小説")
        #expect(result.1 == false)
    }

    @Test
    func appendToEmpty() throws {
        let r1 = MultiValueParser.append(to: "", value: "マンガ")
        #expect(r1.0 == "マンガ")
        #expect(r1.1 == true)
        let r2 = MultiValueParser.append(to: nil, value: "マンガ")
        #expect(r2.0 == "マンガ")
        #expect(r2.1 == true)
    }

    @Test
    func containsCheckCaseSensitive() throws {
        #expect(MultiValueParser.contains("マンガ, 小説", value: "小説") == true)
        #expect(MultiValueParser.contains("マンガ, 小説", value: "Manga") == false)
    }
}
