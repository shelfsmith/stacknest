// SPDX-License-Identifier: MIT
import Foundation
import Security

/// アプリ内蔵サーバのアプリレベル設定（UserDefaults）。トークンは初回アクセス時に生成して永続化。
/// suite 注入はテスト用（既定は .standard）。
public enum ServerPreferences {
    public static let portKey = "server_port"
    public static let tokenKey = "server_token"
    public static let editTokenKey = "server_edit_token"
    public static let defaultPort = 8723

    /// 乱択で避ける「よく使われる」ポート（手動入力には適用しない）。
    public static let blockedPorts: Set<Int> = [
        80, 443, 22, 21, 23, 25, 53, 110, 143, 389, 587, 993, 995,
        3000, 3306, 5000, 5432, 5900, 6379, 7000, 8000, 8080, 8443, 8723, 9000, 9090, 27017
    ]

    /// 1024–65535 から blockedPorts を除いた一様乱数。
    public static func randomPort() -> Int {
        while true {
            let p = Int.random(in: 1024...65535)
            if !blockedPorts.contains(p) { return p }
        }
    }

    public static func port(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: portKey)
        if (1...65535).contains(v) { return v }
        let p = randomPort()
        defaults.set(p, forKey: portKey)
        return p
    }

    public static func setPort(_ port: Int, defaults: UserDefaults = .standard) {
        defaults.set(port, forKey: portKey)
    }

    /// 永続トークン（無ければ 256bit 乱数を base64url で生成・保存）。
    public static func token(defaults: UserDefaults = .standard) -> String {
        if let t = defaults.string(forKey: tokenKey), !t.isEmpty { return t }
        return regenerateToken(defaults: defaults)
    }

    /// 編集（RW）トークン。未生成は nil（キーが無ければ R のみで編集不可）。
    public static func editToken(defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: editTokenKey)
        return (v?.isEmpty == false) ? v : nil
    }

    /// 編集（RW）トークンを生成/再生成して保存・返す（R トークンと同じ 256bit base64url）。
    @discardableResult
    public static func regenerateEditToken(defaults: UserDefaults = .standard) -> String {
        let t = generateToken()
        defaults.set(t, forKey: editTokenKey)
        return t
    }

    /// 編集（RW）トークンを削除（nil 化）。以後 RW 認証は不可になる。
    public static func clearEditToken(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: editTokenKey)
    }

    public static let preferredHostIPKey = "server_preferred_host_ip"

    /// QR に載せる接続先 IP アドレス。未設定は nil（=列挙の先頭を使う）。
    public static func preferredHostIP(defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: preferredHostIPKey)
        return (v?.isEmpty == false) ? v : nil
    }
    public static func setPreferredHostIP(_ ip: String?, defaults: UserDefaults = .standard) {
        if let ip, !ip.isEmpty { defaults.set(ip, forKey: preferredHostIPKey) }
        else { defaults.removeObject(forKey: preferredHostIPKey) }
    }

    @discardableResult
    public static func regenerateToken(defaults: UserDefaults = .standard) -> String {
        let t = generateToken()
        defaults.set(t, forKey: tokenKey)
        return t
    }

    // MARK: - ローカル制御エンドポイント設定（127.0.0.1 専用・CLI/MCP 用）

    private static let localControlPortKey = "local_control_port"
    private static let localControlTokenKey = "local_control_token"
    private static let localAutomationEnabledKey = "local_automation_enabled"

    /// ローカル制御エンドポイントのポート。未設定なら乱数生成して確定保存する。
    public static func localControlPort(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: localControlPortKey)
        if v > 0 { return v }
        let p = randomPort()
        defaults.set(p, forKey: localControlPortKey)
        return p
    }

    /// ローカル制御ポートを再採番して保存・返す（ポート競合時の自動回復用）。
    @discardableResult
    public static func regenerateLocalControlPort(defaults: UserDefaults = .standard) -> Int {
        let p = randomPort()
        defaults.set(p, forKey: localControlPortKey)
        return p
    }

    /// ローカル制御エンドポイントの RW トークン。未設定なら 256bit CSPRNG で生成して確定保存する
    /// （R/RW 共通の generateToken に統一・loopback 専用だが品質を揃える）。
    public static func localControlToken(defaults: UserDefaults = .standard) -> String {
        if let t = defaults.string(forKey: localControlTokenKey), !t.isEmpty { return t }
        let t = generateToken()
        defaults.set(t, forKey: localControlTokenKey)
        return t
    }

    /// ローカル制御エンドポイントの RW トークンを再生成して保存・返す。
    @discardableResult
    public static func regenerateLocalControlToken(defaults: UserDefaults = .standard) -> String {
        let t = generateToken()
        defaults.set(t, forKey: localControlTokenKey)
        return t
    }

    /// ローカルアクセスエンドポイントの有効フラグ（未設定なら true）。
    public static func localAutomationEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: localAutomationEnabledKey) == nil { return true }
        return defaults.bool(forKey: localAutomationEnabledKey)
    }

    /// ローカルアクセスエンドポイントの有効フラグを設定する。
    public static func setLocalAutomationEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: localAutomationEnabledKey)
    }

    // MARK: - 同梱 CLI パス（MCP の自動解決用）

    private static let cliPathKey = "cli_path"

    /// 同梱 stacknest-cli の絶対パス（アプリ起動時に記録・MCP が自動解決に使う）。未記録は nil。
    public static func cliPath(defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: cliPathKey)
        return (v?.isEmpty == false) ? v : nil
    }
    public static func setCLIPath(_ path: String?, defaults: UserDefaults = .standard) {
        if let path, !path.isEmpty { defaults.set(path, forKey: cliPathKey) }
        else { defaults.removeObject(forKey: cliPathKey) }
    }

    // MARK: - 共通トークン生成

    /// 256bit 乱数を base64url で生成する（R/RW トークン共通）。
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // CSPRNG 失敗時のフォールバック（弱いゼロ埋めトークンを絶対に使わない）。
            // SystemRandomNumberGenerator ベースの UInt8.random は暗号品質。
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
