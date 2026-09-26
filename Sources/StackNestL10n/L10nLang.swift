// SPDX-License-Identifier: MIT
import Foundation

/// UI 言語（G55）。対応は日本語と英語だけ。`ja*` 以外はすべて英語。
public enum L10nLang: String, Sendable, CaseIterable {
    case ja, en

    /// 現在の言語。サーバのリクエスト処理中は `requestOverride`（Accept-Language 由来）が勝つ。
    public static var current: L10nLang { requestOverride ?? processDefault }

    /// サーバがリクエストごとに載せる言語（`LanguageMiddleware`）。スコープの外には漏れない。
    @TaskLocal public static var requestOverride: L10nLang?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _processDefault: L10nLang?

    /// プロセス全体の既定。App は起動時に `bootstrap(preferredLocalizations:)` で決める。
    /// 未設定なら `Locale.preferredLanguages` と `STACKNEST_LANG` から求める（CLI の経路）。
    public static var processDefault: L10nLang {
        get {
            lock.lock(); defer { lock.unlock() }
            if let v = _processDefault { return v }
            let v = from(preferredLanguages: Locale.preferredLanguages, env: ProcessInfo.processInfo.environment)
            _processDefault = v
            return v
        }
        set { lock.lock(); _processDefault = newValue; lock.unlock() }
    }

    /// App 起動時に呼ぶ。`Bundle.main.preferredLocalizations` を渡すと、アプリごとの言語設定にも従う。
    public static func bootstrap(preferredLocalizations: [String]) {
        processDefault = resolve(preferredLocalizations: preferredLocalizations)
    }

    /// `preferredLocalizations`（先頭が最優先）から言語を決める純関数。グローバル状態は読み書きしない。
    public static func resolve(preferredLocalizations: [String]) -> L10nLang {
        preferredLocalizations.first.map(from(languageTag:)) ?? .en
    }

    public static func from(languageTag: String) -> L10nLang {
        languageTag.lowercased().hasPrefix("ja") ? .ja : .en
    }

    public static func from(preferredLanguages: [String], env: [String: String]) -> L10nLang {
        if let forced = env["STACKNEST_LANG"], !forced.isEmpty { return from(languageTag: forced) }
        return preferredLanguages.first.map(from(languageTag:)) ?? .en
    }

    /// `Accept-Language: en-US,ja;q=0.8` のような値から、q 値が最大の言語を選ぶ。
    public static func from(acceptLanguage header: String?) -> L10nLang {
        guard let header, !header.isEmpty else { return .en }
        var best: (tag: String, q: Double)?
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let tag = pieces.first, !tag.isEmpty else { continue }
            var q = 1.0
            for p in pieces.dropFirst() where p.hasPrefix("q=") { q = Double(p.dropFirst(2)) ?? 0 }
            if best == nil || q > best!.q { best = (tag, q) }
        }
        return best.map { from(languageTag: $0.tag) } ?? .en
    }
}
