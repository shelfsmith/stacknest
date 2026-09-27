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
    /// テストランナーのプロセスでは、`STACKNEST_LANG` が無ければ ja にする（`isTestProcess` 参照）。
    public static var processDefault: L10nLang {
        get {
            lock.lock(); defer { lock.unlock() }
            if let v = _processDefault { return v }
            let v = from(preferredLanguages: Locale.preferredLanguages,
                         env: ProcessInfo.processInfo.environment,
                         isTestProcess: isTestProcess)
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

    public static func from(preferredLanguages: [String], env: [String: String],
                            isTestProcess: Bool = false) -> L10nLang {
        if let forced = env["STACKNEST_LANG"], !forced.isEmpty { return from(languageTag: forced) }
        if isTestProcess { return .ja }
        return preferredLanguages.first.map(from(languageTag:)) ?? .en
    }

    /// テストランナーの中で動いているか。テストは日本語の原文を期待して書かれているので、
    /// 英語環境の Mac でも `STACKNEST_LANG` 無しで ja に固定する（テストから `processDefault`
    /// へ書き込むと並列実行で競合するため、既定値の決め方そのものを変える）。
    /// Swift Testing は環境変数を持たないので、SwiftPM のランナー名（`swiftpm-testing-helper`）、
    /// XCTest のランナー名（`xctest`）、Xcode が渡す `XCTestConfigurationFilePath`、
    /// XCTest の読み込みのいずれかで判定する。App のテストは `bootstrap` が上書きするので影響しない。
    static let isTestProcess: Bool = {
        let info = ProcessInfo.processInfo
        return info.processName == "swiftpm-testing-helper"
            || info.processName == "xctest"
            || info.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// `Accept-Language: en-US,ja;q=0.8` のような値から、q 値が最大の言語を選ぶ。
    /// ヘッダが無い・空・解釈できないときは `fallback`（既定はサーバ自身の言語 `processDefault`）。
    public static func from(acceptLanguage header: String?,
                            fallback: @autoclosure () -> L10nLang = processDefault) -> L10nLang {
        guard let header, !header.isEmpty else { return fallback() }
        var best: (tag: String, q: Double)?
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let tag = pieces.first, !tag.isEmpty else { continue }
            var q = 1.0
            for p in pieces.dropFirst() where p.hasPrefix("q=") { q = Double(p.dropFirst(2)) ?? 0 }
            if best == nil || q > best!.q { best = (tag, q) }
        }
        return best.map { from(languageTag: $0.tag) } ?? fallback()
    }
}
