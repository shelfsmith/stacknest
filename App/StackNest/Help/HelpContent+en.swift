// SPDX-License-Identifier: MIT

/// アプリ内ヘルプの英語本文。段 0 では未着手のため `ja` を返す（U5 が本文に置き換える）。
extension HelpContent {
    static var en: [HelpSection] { ja }
}
