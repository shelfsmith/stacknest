// SPDX-License-Identifier: MIT
import StackNestL10n

/// アプリ内ヘルプ（`HelpView`）の 1 ブロック。
/// `para`/`bullet` は Markdown の行内装飾（`Text(.init(text))` で描画）を含みうる。
enum HelpBlock: Equatable {
    case para(String)
    case bullet(String)
    case keyRow(action: String, keys: String)
    /// 内蔵ビューアのキー表（`ViewerHelpOverlayView.grouped`）を動的に描画する印。本文を持たない。
    case viewerKeyTable
    case link(label: String, url: String)
}

/// ヘルプの 1 節（見出し＋ブロック列）。
struct HelpSection: Equatable {
    let title: String
    let blocks: [HelpBlock]
}

/// ヘルプ本文のデータ（日英）。描画は `HelpView` が担い、ここは静的データのみを持つ。
enum HelpContent {
    /// U5 で英語の本文が入るまでは `false`。`true` になるまで `sections(for: .en)` は `ja` を返す。
    static let hasEnglish = false

    static func sections(for lang: L10nLang) -> [HelpSection] {
        switch lang {
        case .ja: ja
        case .en: hasEnglish ? en : ja
        }
    }

    static var heading: (title: String, subtitle: String) {
        switch L10nLang.current {
        case .ja: ("StackNest ヘルプ", "操作リファレンス") // l10n:ignore help heading (per-language data)
        case .en: ("StackNest Help", "Reference")
        }
    }

    static let repoURL = "https://github.com/shelfsmith/stacknest"
}
