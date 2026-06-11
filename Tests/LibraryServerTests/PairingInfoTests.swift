// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryServer

@Suite("PairingInfo URL")
struct PairingInfoTests {
    /// ペアリング URL はトークンを fragment（#）に置く（サーバへ送信されない）。
    @Test func buildsURLWithTokenInFragment() {
        let url = PairingInfo.url(host: "192.168.1.42", port: 8723, token: "abc-123")
        #expect(url == "http://192.168.1.42:8723/#token=abc-123")
    }
    @Test func bracketsIPv6Host() {
        let url = PairingInfo.url(host: "2400:1:2::3", port: 8723, token: "t")
        #expect(url == "http://[2400:1:2::3]:8723/#token=t")
    }
    @Test func leavesAlreadyBracketedHost() {
        let url = PairingInfo.url(host: "[2400:1:2::3]", port: 8723, token: "t")
        #expect(url == "http://[2400:1:2::3]:8723/#token=t")
    }
    @Test func leavesIPv4Unbracketed() {
        let url = PairingInfo.url(host: "192.168.1.42", port: 8723, token: "t")
        #expect(url == "http://192.168.1.42:8723/#token=t")
    }
}
