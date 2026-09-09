// SPDX-License-Identifier: MIT
import Foundation

/// 現在の ViewerKeyBindings からヘルプ表の行を生成する（セクション順→表示順のフラット配列）。
/// HUD（ViewerHelpOverlayView）と HelpView が共有する単一ソース。
public enum ViewerHelpRows {
    public static func make(from bindings: ViewerKeyBindings) -> [(action: String, keys: String)] {
        ViewerActionSection.allCases.flatMap { section in
            section.actions.map { action in
                (action: action.displayName, keys: keysString(for: action, in: bindings))
            }
        }
    }

    /// セクション見出し付きのヘルプ表（HUD オーバーレイ / ヘルプページ共有）。
    /// `including` を渡すとその集合にあるアクションだけを出し、空になったセクションは省く（G51: EPUB 用）。
    public static func makeGrouped(
        from bindings: ViewerKeyBindings,
        including: Set<ViewerAction>? = nil
    ) -> [(section: String, rows: [(action: String, keys: String)])] {
        ViewerActionSection.allCases.compactMap { section in
            let actions = section.actions.filter { including?.contains($0) ?? true }
            guard !actions.isEmpty else { return nil }
            return (section: section.title,
                    rows: actions.map { (action: $0.displayName, keys: keysString(for: $0, in: bindings)) })
        }
    }

    private static func keysString(for action: ViewerAction, in bindings: ViewerKeyBindings) -> String {
        let parts = bindings.boundBindings(for: action).map { capture -> String in
            switch capture {
            case .chord(let c):     return KeyDisplay.chord(c)
            case .character(let s): return KeyDisplay.character(s)
            }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " / ")
    }
}
