// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestL10n

/// Codex レビュー P2: CLI の書式指定子が `%d`（32bit）のまま `Int`（64bit の書籍 ID 等）を
/// 渡していたため、Int32.max を超える ID で切り詰めが起きていた
/// （例: id=4294967297 → 「id=1」と表示される）。`%lld` へ揃えたことを確認する。
///
/// TDD: 下の 3 つの鍵は、修正前は "...%d)" だった（本番の `Sources/StackNestL10n/Tables/L10n+CLI.swift`
/// および `Sources/StackNestCLI/Stacknest.swift` の呼び出し箇所）。まずその鍵のまま実行して赤にし、
/// 修正（鍵自体を "...%lld)" へ変更）と同時にここも書き換えて緑にした。
///
/// `L10n.format`/`L10n.plural` は `locale: nil`（POSIX）で固定されている（G55 回帰修正、
/// 別コミット）ので、桁区切りのカンマは入らない。ここでは正確な文字列一致で検証する。
@Suite("CLI の書式指定子は 64bit 引数に対して %lld を使う（Codex レビュー P2）")
struct L10nCLI64BitTests {
    /// Int32.max（2147483647）を超える書籍 ID。`%d` だと下位 32bit だけが読まれ「1」になる。
    private static let bigID = 4_294_967_297

    @Test("rm: 削除しました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func removedMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("削除しました (id=%lld)", Self.bigID) == "削除しました (id=4294967297)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("削除しました (id=%lld)", Self.bigID) == "Removed (id=4294967297)")
        }
    }

    @Test("set: 更新しました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func updatedMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("更新しました (id=%lld)", Self.bigID) == "更新しました (id=4294967297)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("更新しました (id=%lld)", Self.bigID) == "Updated (id=4294967297)")
        }
    }

    @Test("relink: 再リンクしました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func relinkMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("再リンクしました (id=%lld)", Self.bigID) == "再リンクしました (id=4294967297)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("再リンクしました (id=%lld)", Self.bigID) == "Relinked (id=4294967297)")
        }
    }

    /// 本番辞書（`L10nTable.all`）に `%d`/`%1$d` 系の 32bit int 指定子が残っていないことを
    /// 恒久的に検査する（回帰防止。個別の legit Int32 例外があればここに追記する）。
    @Test("全辞書: 32bit int 指定子(%d 系)は使わない（Int は必ず %lld）")
    func no32BitIntSpecifiersInAnyTable() {
        // `%d` 系（%d, %1$d, %05d, %ld, %hd, %hhd ...）にマッチし、`%lld` にはマッチしない。
        // (`%lld` は最初の `l` の直後に `d` が来ないため、この正規表現は "%" の位置から連続一致できない)
        let badPattern = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|l|q|z|t|j)?d"#)
        func hasBadSpecifier(_ s: String) -> Bool {
            let ns = s as NSString
            return badPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }
        for (key, entry) in L10nTable.all {
            #expect(!hasBadSpecifier(key), "32bit int specifier (%d系) in key: \(key)")
            if let p = entry.enPlural {
                #expect(!hasBadSpecifier(p.one), "32bit int specifier (%d系) in en(one) for: \(key)")
                #expect(!hasBadSpecifier(p.other), "32bit int specifier (%d系) in en(other) for: \(key)")
            } else {
                #expect(!hasBadSpecifier(entry.en), "32bit int specifier (%d系) in en for: \(key)")
            }
        }
    }
}
