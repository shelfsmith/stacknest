// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackNestL10n
@testable import StackNestCLI

@Suite("CLI は Accept-Language を送る（G55）")
struct AcceptLanguageHeaderTests {
    /// 並行テストのため `L10nLang.processDefault` には触れない。CLI は常に `L10nLang.current`
    /// （リクエストオーバーライドが無ければ processDefault と同じ）をヘッダに載せるので、
    /// `$requestOverride.withValue` でスコープ限定に切り替えて確認する。
    @Test("L10nLang.current の言語をヘッダに載せる", arguments: [L10nLang.ja, .en])
    func sendsLanguage(lang: L10nLang) throws {
        let client = APIClient(endpoint: ResolvedEndpoint(baseURL: "http://127.0.0.1:9", token: "t"))
        let req = L10nLang.$requestOverride.withValue(lang) {
            client.makeRequestForTesting(path: "/libraries")
        }
        #expect(req.value(forHTTPHeaderField: "Accept-Language") == lang.rawValue)
    }
}
