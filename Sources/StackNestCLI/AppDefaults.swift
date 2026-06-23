// SPDX-License-Identifier: MIT
import Foundation

/// アプリ(app.shelfsmith.stacknest)の UserDefaults からローカル制御 port/token を読む。
enum AppDefaults {
    private static var suite: UserDefaults? { UserDefaults(suiteName: "app.shelfsmith.stacknest") }
    static func localPort() -> Int { suite?.integer(forKey: "local_control_port") ?? 0 }
    static func localToken() -> String { suite?.string(forKey: "local_control_token") ?? "" }
}
