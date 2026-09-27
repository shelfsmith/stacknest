// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import StackNestL10n
@testable import LibraryServer

@Suite("Accept-Language でリクエストの言語を決める（G55）")
struct LanguageMiddlewareTests {
    private func makeApp() -> some ApplicationProtocol {
        let router = Router()
        router.add(middleware: LanguageMiddleware())
        router.get("lang") { _, _ in L10nLang.current.rawValue }
        return Application(router: router)
    }

    @Test("ヘッダの言語がハンドラの L10nLang.current になる", arguments: [
        ("ja,en;q=0.8", "ja"), ("en-US,ja;q=0.5", "en"), ("fr", "en"),
    ])
    func headerDrivesLanguage(header: String, expected: String) async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/lang", method: .get, headers: [.acceptLanguage: header]) { res in
                #expect(String(buffer: res.body) == expected)
            }
        }
    }

    /// 最終レビュー item 3: ヘッダが無ければサーバの既定言語（ホストの言語 = processDefault）。
    /// テストプロセスの processDefault は ja（`L10nLang.isTestProcess`）なので、旧挙動（常に en）と区別できる。
    @Test("ヘッダが無い・空ならサーバの既定言語", arguments: [nil, ""] as [String?])
    func noHeaderUsesHostLanguage(header: String?) async throws {
        try await makeApp().test(.router) { client in
            let headers: HTTPFields = header.map { [.acceptLanguage: $0] } ?? [:]
            try await client.execute(uri: "/lang", method: .get, headers: headers) { res in
                #expect(String(buffer: res.body) == L10nLang.processDefault.rawValue)
            }
        }
    }

    /// Review Focus 5: 並行したリクエストの間で言語が混ざらない。
    @Test("ja と en を並行に投げても互いに漏れない")
    func concurrentRequestsDoNotLeak() async throws {
        try await makeApp().test(.router) { client in
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                for i in 0..<40 {
                    let want = i.isMultiple(of: 2) ? "ja" : "en"
                    group.addTask {
                        try await client.execute(uri: "/lang", method: .get, headers: [.acceptLanguage: want]) { res in
                            (want, String(buffer: res.body))
                        }
                    }
                }
                for try await (want, got) in group { #expect(want == got) }
            }
        }
    }
}
