// SPDX-License-Identifier: MIT
import SwiftUI

/// 「共有」トップレベルメニュー。共有設定・サーバ接続・オフライン閲覧を集約。
struct ShareCommands: Commands {
    let openWindow: OpenWindowAction
    var body: some Commands {
        CommandMenu("共有") {
            Button("サーバ設定…") { openWindow(id: "sharing-settings") }
            Divider()
            Button("リモートビューア…") { openWindow(id: "connect") }
            Button("オフラインビューア…") { openWindow(id: "offline") }
        }
    }
}
