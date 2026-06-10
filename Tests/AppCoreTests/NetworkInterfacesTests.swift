// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("NetworkInterfaces IPv4 enumeration")
struct NetworkInterfacesTests {
    /// 環境依存のため弱い検証: loopback(lo0) を含まず、各エントリは IPv4 ドット表記。
    @Test func excludesLoopbackAndReturnsIPv4Strings() {
        let addrs = NetworkInterfaces.ipv4Addresses()
        for a in addrs {
            #expect(a.interface != "lo0")
            // IPv4 形式: 4 オクテット・各 0-255
            let parts = a.ip.split(separator: ".")
            #expect(parts.count == 4)
            for p in parts {
                if let n = Int(p) {
                    #expect((0...255).contains(n))
                } else {
                    Issue.record("non-numeric IPv4 octet: \(a.ip)")
                }
            }
            #expect(!a.ip.isEmpty)
        }
    }
}
