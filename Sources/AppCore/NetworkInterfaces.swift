// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// この Mac の IPv4 / IPv6 アドレス列挙（Web クライアント接続先 URL の提示用）。
/// en0 を先頭に、loopback(lo0) / link-local(fe80::) を除外し、物理系 → utun(Tailscale) の順で返す。
public enum NetworkInterfaces {
    public enum Family: Sendable, Equatable {
        case ipv4
        case ipv6
    }

    public struct Address: Sendable, Equatable {
        public let interface: String   // "en0" / "utun3" など
        public let ip: String          // "192.168.x.x" / "2400:1:2::3"
        public let family: Family

        public init(interface: String, ip: String, family: Family) {
            self.interface = interface
            self.ip = ip
            self.family = family
        }

        /// URL のホスト部として使える文字列。IPv6 は角括弧で囲む（RFC 2732）。
        public var displayHost: String {
            family == .ipv6 ? "[\(ip)]" : ip
        }
    }

    // en0 優先 → 物理系 → utun(Tailscale) の rank
    private static func rank(_ n: String) -> Int {
        n == "en0" ? 0 : (n.hasPrefix("utun") ? 2 : 1)
    }

    public static func ipv4Addresses() -> [Address] {
        var result: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ifa.ifa_addr!, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            result.append(Address(interface: name, ip: ip, family: .ipv4))
        }
        return result.sorted { rank($0.interface) < rank($1.interface) }
    }

    public static func ipv6Addresses() -> [Address] {
        var result: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ifa.ifa_addr!, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // link-local アドレス(fe80::)を除外
            guard !ip.lowercased().hasPrefix("fe80") else { continue }
            result.append(Address(interface: name, ip: ip, family: .ipv6))
        }
        return result.sorted { rank($0.interface) < rank($1.interface) }
    }

    /// IPv4 → IPv6 の順に並べた統合アドレス一覧（en0 優先・utun 後方）。
    public static func addresses() -> [Address] {
        ipv4Addresses() + ipv6Addresses()
    }
}
