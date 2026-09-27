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
/// `L10n.format` は `String(format:locale:arguments:)` に `locale:` を渡すため、`%d` でも `%lld` でも
/// 桁区切りのカンマが入る（例: "4,294,967,297"）。これは今回の修正と無関係な既存の Foundation の挙動
/// （`%d`/`%lld` どちらでも同じ）なので、比較の際はカンマを取り除いてから数値として突き合わせる。
@Suite("CLI の書式指定子は 64bit 引数に対して %lld を使う（Codex レビュー P2）")
struct L10nCLI64BitTests {
    /// Int32.max（2147483647）を超える書籍 ID。`%d` だと下位 32bit だけが読まれ「1」になる。
    private static let bigID = 4_294_967_297

    private static func digitsAfter(_ marker: String, in s: String) -> String? {
        guard let range = s.range(of: marker) else { return nil }
        let rest = s[range.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "," }
        return String(digits).replacingOccurrences(of: ",", with: "")
    }

    @Test("rm: 削除しました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func removedMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            let s = L10n.format("削除しました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            let s = L10n.format("削除しました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
        }
    }

    @Test("set: 更新しました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func updatedMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            let s = L10n.format("更新しました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            let s = L10n.format("更新しました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
        }
    }

    @Test("relink: 再リンクしました (id=...) が巨大 ID を切り詰めない（ja/en）")
    func relinkMessageKeepsFullID() {
        L10nLang.$requestOverride.withValue(.ja) {
            let s = L10n.format("再リンクしました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
        }
        L10nLang.$requestOverride.withValue(.en) {
            let s = L10n.format("再リンクしました (id=%lld)", Self.bigID)
            #expect(Self.digitsAfter("id=", in: s) == "4294967297", "got: \(s)")
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
