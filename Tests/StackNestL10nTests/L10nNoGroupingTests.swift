// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestL10n

/// G55 回帰修正: `L10n.format`/`L10n.plural` が `String(format:locale:arguments:)` に
/// `Locale(ja_JP/en_US)` を渡していたため、数値に桁区切りのカンマが入っていた
/// （例: id=1234 → "id=1,234"）。G55 以前は素の Swift 文字列補間（"id=\(id)"）で
/// カンマは入らなかったので、これは新しい退行。書籍 ID にカンマが入るとコマンドへの
/// コピペが壊れるため、`locale: nil`（POSIX: 桁区切り無し・小数点は "."）に戻す。
/// 複数形の選択（単数/複数）は引き続き言語で決める。
@Suite("L10n.format/plural は桁区切りを入れない（G55 回帰修正）")
struct L10nNoGroupingTests {
    @Test("小さい整数はカンマ無し（ja/en）")
    func smallIntegerHasNoGrouping() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("id=%lld", 1234) == "id=1234")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("id=%lld", 1234) == "id=1234")
        }
    }

    @Test("64bit の大きな整数もカンマ無し（ja/en）")
    func bigIntegerHasNoGrouping() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("id=%lld", 4_294_967_297) == "id=4294967297")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("id=%lld", 4_294_967_297) == "id=4294967297")
        }
    }

    @Test("小数点は . のまま（ja/en）")
    func decimalPointStaysDot() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("%.1f MB", 1234.5) == "1234.5 MB")
        }
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10n.format("%.1f MB", 1234.5) == "1234.5 MB")
        }
    }
}
