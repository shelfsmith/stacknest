// SPDX-License-Identifier: MIT
import Foundation

/// 種まきした既定の名前（保存値は日本語のまま・G55 で不変）を、画面や CLI の人向け出力で
/// 訳して見せるための共有ヘルパ。App（AppCore）と CLI（AppCore に依存しない）の両方から使う。
/// **表示専用。** 保存・照合・DTO・`--json` には使わない。
public enum L10nSeed {
    /// `GrantStore` が種まきする既定グラントのラベル（UserDefaults の保存値）。
    /// 1 行 1 リテラル（`l10n:ignore` は日本語リテラルが 1 つの行にだけ効く・G56）。
    public static let grantLabels: Set<String> = [
        "(既定) 閲覧",  // l10n:ignore stored seed value (language-independent); display via grantLabel(_:)
        "(既定) 編集",  // l10n:ignore stored seed value (language-independent); display via grantLabel(_:)
    ]

    /// 保存値がちょうど既定ラベルなら現在の言語に訳し、それ以外（利用者が付けた名前・改名後の値）はそのまま。
    public static func grantLabel(_ storedLabel: String, _ lang: L10nLang = .current) -> String {
        grantLabels.contains(storedLabel) ? L10n.text(storedLabel, lang) : storedLabel
    }

    /// 棚の表示名。お気に入り棚（`kind == "favorites"`）は保存名に関わらず画面と同じ固定の名前にする。
    public static func shelfTitle(_ storedTitle: String, kind: String, _ lang: L10nLang = .current) -> String {
        kind == "favorites" ? L10n.text("お気に入り", lang) : storedTitle
    }
}
