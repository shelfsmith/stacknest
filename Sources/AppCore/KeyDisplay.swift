// SPDX-License-Identifier: MIT
import Foundation

/// KeyChord / 文字を人間可読のキー表記へ整形する（AppKit 非依存）。
/// 文字キーは keyCode 名称に頼らず文字を表示（配列非依存）。非文字キーのみ名称テーブルを持つ。
public enum KeyDisplay {
    /// keyCode → 名称（非文字キーのみ。文字キーは characterMap で扱うのでここには持たない）。
    private static let keyCodeNames: [UInt16: String] = [
        49: "Space", 48: "Tab", 53: "Esc", 36: "Return", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        24: "=", 27: "-", 30: "]", 33: "[",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func chord(_ chord: KeyChord) -> String {
        var prefix = ""
        if chord.modifiers & KeyChord.control != 0 { prefix += "⌃" }
        if chord.modifiers & KeyChord.option  != 0 { prefix += "⌥" }
        if chord.modifiers & KeyChord.shift   != 0 { prefix += "⇧" }
        if chord.modifiers & KeyChord.command != 0 { prefix += "⌘" }
        let name = keyCodeNames[chord.keyCode] ?? keyCodeLetter(chord.keyCode) ?? "key\(chord.keyCode)"
        return prefix + name
    }

    public static func character(_ s: String) -> String { s }

    /// ⌘ 付き等で chord に入った英字キーの表示用（keyCode → 大文字英字）。US 配列基準の補助。
    /// 不明なら nil（呼び出し側が "key{N}" にフォールバック）。
    private static func keyCodeLetter(_ keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z",
        ]
        return map[keyCode]
    }
}
