// SPDX-License-Identifier: MIT
import Foundation

/// ペアリング URL（QR の中身）。トークンは URL fragment（サーバに送信されない）で渡す。
public enum PairingInfo {
    public static func url(host: String, port: Int, token: String) -> String {
        let h = formatHost(host)
        return "http://\(h):\(port)/#token=\(token)"
    }

    /// IPv6（コロンを含み、未ブラケット）なら角括弧で囲む。
    private static func formatHost(_ host: String) -> String {
        if host.hasPrefix("[") { return host }
        if host.contains(":") { return "[\(host)]" }
        return host
    }
}
