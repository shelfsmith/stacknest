// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import StackNest

/// G56-S1: ヘルプに出るメニュー・タブ・ボタンの名前が、画面の表記（カタログ）と一致することを守る。
enum HelpLabelExtraction {
    /// `"…"` の中身。
    static func quotedNames(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "\"") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\"") else { break }
            let name = rest[after..<close].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    private static let stops: Set<Character> = ["▸", ".", ",", ";", ":", "(", ")", "—", "\"", "*", "\n"]

    /// `▸` の直後の名前。
    static func arrowNames(_ text: String) -> [String] {
        var out: [String] = []
        let parts = text.components(separatedBy: "▸").dropFirst()
        for part in parts {
            var s = Substring(part).drop(while: { $0 == " " })
            if s.hasPrefix("**"), let end = s.dropFirst(2).range(of: "**") {
                out.append(String(s.dropFirst(2)[..<end.lowerBound]).trimmingCharacters(in: .whitespaces))
                continue
            }
            if s.hasPrefix("\""), let end = s.dropFirst().firstIndex(of: "\"") {
                out.append(String(s.dropFirst()[..<end]).trimmingCharacters(in: .whitespaces))
                continue
            }
            s = s.prefix(while: { !stops.contains($0) })
            let name = s.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
        }
        return out
    }
}

@Suite("G56-S1: ヘルプの UI 名が画面の表記と一致する")
struct HelpLabelCatalogTests {
    /// UI 名ではない引用・名前（理由付き）。最小に保つ。
    static let notUINames: [String: String] = [
        "⇧/⌘ View Toggle & Selection": "複数の操作をまとめたヘルプの見出しで、画面上の単一の UI 名ではない",
        "+": "ツールバーのアイコンボタン（＋）で、テキストとしてカタログには無い",
        "Command Line / AI Access": "ヘルプ内の別セクション見出しへの参照で、画面の UI 名ではない",
        "Open Source and Acknowledgments": "ヘルプ内の別セクション見出しへの参照で、画面の UI 名ではない",
        "Reduce Motion": "macOS システム設定の項目名で、StackNest 自身のカタログには無い",
        "Resume Reading": "Web の文言（i18n-en.js）",
        ",": "区切り文字の例示（タグ名の例）で、画面の UI 名ではない",
    ]

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StackNest/Localizable.xcstrings")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return obj["strings"] as! [String: Any]
    }

    private func englishValues() throws -> Set<String> {
        var out: Set<String> = []
        for (_, v) in try catalog() {
            guard let en = ((v as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any] else { continue }
            if let value = (en["stringUnit"] as? [String: Any])?["value"] as? String { out.insert(value) }
            if let plural = (en["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                for (_, form) in plural {
                    if let value = ((form as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { out.insert(value) }
                }
            }
        }
        return out
    }

    private func texts(_ sections: [HelpSection]) -> [String] {
        sections.flatMap(\.blocks).compactMap {
            switch $0 {
            case .para(let s), .bullet(let s): return s
            default: return nil
            }
        }
    }

    private func actions(_ sections: [HelpSection]) -> [String] {
        sections.flatMap(\.blocks).compactMap {
            if case .keyRow(let action, _) = $0 { return action } else { return nil }
        }
    }

    @Test func extractionRules() {
        #expect(HelpLabelExtraction.quotedNames(#"Turn on "Page Turn Effect" and "Key Bindings"."#) == ["Page Turn Effect", "Key Bindings"])
        #expect(HelpLabelExtraction.arrowNames("under Settings (⌘,) ▸ At Startup. Each") == ["At Startup"])
        #expect(HelpLabelExtraction.arrowNames(#"Settings ▸ View ▸ "EPUB Color Theme" picks"#) == ["View", "EPUB Color Theme"])
        #expect(HelpLabelExtraction.arrowNames("File menu ▸ **Integrity Check…** runs") == ["Integrity Check…"])
        #expect(HelpLabelExtraction.arrowNames("Settings ▸ Import (Watched Folders)") == ["Import"])
    }

    @Test func englishHelpNamesExistInCatalog() throws {
        let en = try englishValues()
        let body = texts(HelpContent.en)
        let names = body.flatMap(HelpLabelExtraction.quotedNames) + body.flatMap(HelpLabelExtraction.arrowNames)
            + actions(HelpContent.en)
        let missing = Set(names).filter { !en.contains($0) && Self.notUINames[$0] == nil }.sorted()
        #expect(missing == [], "英語ヘルプの名前が画面の表記に無い: \(missing)")
    }

    @Test func japaneseHelpArrowNamesExistInCatalog() throws {
        let keys = Set(try catalog().keys)
        let names = texts(HelpContent.ja).flatMap(HelpLabelExtraction.arrowNames)
        let missing = Set(names).filter { !keys.contains($0) && Self.notUINames[$0] == nil }.sorted()
        #expect(missing == [], "日本語ヘルプの名前がカタログのキーに無い: \(missing)")
    }
}
