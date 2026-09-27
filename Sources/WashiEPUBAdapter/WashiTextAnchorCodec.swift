// SPDX-License-Identifier: MIT
import Foundation

/// G56-S2: Washi の文の位置（`EPUBLocator.textOffset`＋`idref`）を、契約の `EPUBLocatorValue.cfi` に詰める書式。
/// `cfi` は「同じエンジン同士で復元精度を上げる補助」の枠で、`engine == "washi"` のときだけこの書式になる。
/// 書式: `washi:t=<UTF-16 オフセット>;idref=<パーセント符号化した idref>`。未知のキーは読み飛ばす（将来の追加に備える）。
/// 壊れた値は「アンカー無し」として nil を返す（例外にしない＝進行率での復元に落ちる）。
enum WashiTextAnchorCodec {
    static let prefix = "washi:"

    /// idref の中の区切り文字を逃がす（`;` `=` `%` を含みうる）。
    private static let idrefAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ";=%&+")
        return set
    }()

    static func encode(textOffset: Int, idref: String?) -> String {
        var s = "\(prefix)t=\(textOffset)"
        if let idref, let escaped = idref.addingPercentEncoding(withAllowedCharacters: idrefAllowed) {
            s += ";idref=\(escaped)"
        }
        return s
    }

    static func decode(_ cfi: String?) -> (textOffset: Int, idref: String?)? {
        guard let cfi, cfi.hasPrefix(prefix) else { return nil }
        var offset: Int?
        var idref: String?
        for field in cfi.dropFirst(prefix.count).split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "t": offset = Int(parts[1])
            case "idref": idref = parts[1].removingPercentEncoding
            default: continue
            }
        }
        guard let offset, offset >= 0 else { return nil }
        return (offset, idref)
    }
}
