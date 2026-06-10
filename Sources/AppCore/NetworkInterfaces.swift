// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// この Mac の IPv4 アドレス列挙（Web クライアント接続先 URL の提示用）。
/// en0 を先頭に、loopback(lo0) を除外し、物理系 → utun(Tailscale) の順で返す。
public enum NetworkInterfaces {
    public struct Address: Sendable, Equatable {
        public let interface: String   // "en0" / "utun3" など
        public let ip: String          // "192.168.x.x"

        public init(interface: String, ip: String) {
            self.interface = interface
            self.ip = ip
        }
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
            var addr = sa.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&addr, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Address(interface: name, ip: String(cString: host)))
        }
        // en0 優先 → 物理系 → utun(Tailscale)
        return result.sorted { lhs, rhs in
            func rank(_ n: String) -> Int { n == "en0" ? 0 : (n.hasPrefix("utun") ? 2 : 1) }
            return rank(lhs.interface) < rank(rhs.interface)
        }
    }
}
