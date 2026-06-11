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
            #expect(a.family == .ipv4)
        }
    }
}

@Suite("NetworkInterfaces IPv6 + unified")
struct NetworkInterfacesIPv6Tests {
    @Test func ipv6ExcludesLoopbackAndLinkLocal() {
        for a in NetworkInterfaces.ipv6Addresses() {
            #expect(a.interface != "lo0")
            #expect(!a.ip.lowercased().hasPrefix("fe80"))
            #expect(a.ip.contains(":"))
            #expect(a.family == .ipv6)
        }
    }
    @Test func displayHostBracketsIPv6() {
        let v6 = NetworkInterfaces.Address(interface: "en0", ip: "2400:1:2::3", family: .ipv6)
        #expect(v6.displayHost == "[2400:1:2::3]")
        let v4 = NetworkInterfaces.Address(interface: "en0", ip: "192.168.1.2", family: .ipv4)
        #expect(v4.displayHost == "192.168.1.2")
    }
    @Test func unifiedAddressesPutsIPv4First() {
        let all = NetworkInterfaces.addresses()
        if let firstV6 = all.firstIndex(where: { $0.family == .ipv6 }),
           let lastV4 = all.lastIndex(where: { $0.family == .ipv4 }) {
            #expect(lastV4 < firstV6)
        }
    }
}
