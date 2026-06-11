// SPDX-License-Identifier: MIT
import Foundation
import Security

/// アプリ内蔵サーバのアプリレベル設定（UserDefaults）。トークンは初回アクセス時に生成して永続化。
/// suite 注入はテスト用（既定は .standard）。
public enum ServerPreferences {
    public static let portKey = "server_port"
    public static let tokenKey = "server_token"
    public static let defaultPort = 8723

    public static func port(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: portKey)
        return (1...65535).contains(v) ? v : defaultPort
    }

    public static func setPort(_ port: Int, defaults: UserDefaults = .standard) {
        defaults.set(port, forKey: portKey)
    }

    /// 永続トークン（無ければ 256bit 乱数を base64url で生成・保存）。
    public static func token(defaults: UserDefaults = .standard) -> String {
        if let t = defaults.string(forKey: tokenKey), !t.isEmpty { return t }
        return regenerateToken(defaults: defaults)
    }

    public static let preferredInterfaceKey = "server_preferred_interface"

    /// QR に載せる接続先 NIC（interface 名）。未設定は nil（=列挙の先頭を使う）。
    public static func preferredInterface(defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: preferredInterfaceKey)
        return (v?.isEmpty == false) ? v : nil
    }
    public static func setPreferredInterface(_ name: String?, defaults: UserDefaults = .standard) {
        if let name, !name.isEmpty { defaults.set(name, forKey: preferredInterfaceKey) }
        else { defaults.removeObject(forKey: preferredInterfaceKey) }
    }

    @discardableResult
    public static func regenerateToken(defaults: UserDefaults = .standard) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // CSPRNG 失敗時のフォールバック（弱いゼロ埋めトークンを絶対に使わない）。
            // SystemRandomNumberGenerator ベースの UInt8.random は暗号品質。
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let t = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        defaults.set(t, forKey: tokenKey)
        return t
    }
}
