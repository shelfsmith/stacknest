// SPDX-License-Identifier: MIT
import Foundation

/// ペアリング URL（QR の中身）。トークンは URL fragment（サーバに送信されない）で渡す。
public enum PairingInfo {
    public static func url(host: String, port: Int, token: String) -> String {
        "http://\(host):\(port)/#token=\(token)"
    }
}
