// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestCLI

@Suite("EndpointResolver")
struct EndpointResolverTests {
    @Test func explicitOverridesWin() {
        let r = EndpointResolver.resolve(urlArg: "http://host:9000", tokenArg: "T",
            env: [:], defaultsPort: 1, defaultsToken: "D")
        #expect(r?.baseURL == "http://host:9000"); #expect(r?.token == "T")
    }
    @Test func envUsedWhenNoArgs() {
        let r = EndpointResolver.resolve(urlArg: nil, tokenArg: nil,
            env: ["STACKNEST_URL": "http://e:1", "STACKNEST_TOKEN": "ET"], defaultsPort: 1, defaultsToken: "D")
        #expect(r?.baseURL == "http://e:1"); #expect(r?.token == "ET")
    }
    @Test func fallsBackToAppDefaults() {
        let r = EndpointResolver.resolve(urlArg: nil, tokenArg: nil, env: [:], defaultsPort: 8765, defaultsToken: "D")
        #expect(r?.baseURL == "http://127.0.0.1:8765"); #expect(r?.token == "D")
    }
    @Test func nilWhenNoTokenAvailable() {
        let r = EndpointResolver.resolve(urlArg: nil, tokenArg: nil, env: [:], defaultsPort: 0, defaultsToken: "")
        #expect(r == nil)
    }
}
