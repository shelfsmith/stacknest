// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import StackNestL10n
@testable import StackNestCLI

/// G55 U7: `--json` の出力（`JSONEncoder` の対象・キー・列挙値）は言語設定を一切見ない。
/// `STACKNEST_LANG=en` でもキー集合が ja と変わらないことを固定する回帰テスト。
/// 並行テストのため `L10nLang.processDefault` には触れず、`$requestOverride.withValue` で
/// スコープ限定に言語を切り替える（`STACKNEST_LANG` を注入した場合と同じ経路 `L10nLang.current`
/// を通る）。JSONEncoder はキーの出力順を保証しないため（同一プロセス内でも呼び出しごとに
/// 変わりうる）、比較はバイト列ではなくデコードしたキー集合で行う。
@Suite("--json output is language-invariant (G55)")
struct JSONOutputLanguageInvarianceTests {
    private static func keySet(of data: Data) throws -> Swift.Set<String> {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj.map { Swift.Set($0.keys) } ?? []
    }

    @Test("AddBooksReplyDTO のキー集合は ja/en で同一")
    func addReplyKeySetIsLanguageInvariant() throws {
        let reply = AddBooksReplyDTO(addedIDs: [1, 2], alreadyPresent: ["a.zip"], failed: ["b.zip"])
        func keys(_ lang: L10nLang) throws -> Swift.Set<String> {
            let data = try L10nLang.$requestOverride.withValue(lang) {
                try JSONEncoder().encode(reply)
            }
            return try Self.keySet(of: data)
        }
        #expect(try keys(.ja) == keys(.en))
        #expect(try keys(.ja) == ["addedIDs", "alreadyPresent", "failed"])
    }

    @Test("StampApplyReply のキー集合は ja/en で同一")
    func stampApplyReplyKeySetIsLanguageInvariant() throws {
        let reply = StampApplyReply(updated: 3)
        func keys(_ lang: L10nLang) throws -> Swift.Set<String> {
            let data = try L10nLang.$requestOverride.withValue(lang) {
                try JSONEncoder().encode(reply)
            }
            return try Self.keySet(of: data)
        }
        #expect(try keys(.ja) == keys(.en))
        #expect(try keys(.ja) == ["updated"])
    }
}
