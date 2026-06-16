// SPDX-License-Identifier: MIT
import SwiftUI

/// 「共有」トップレベルメニュー。共有設定・サーバ接続・オフライン閲覧を集約。
struct ShareCommands: Commands {
    let openWindow: OpenWindowAction
    var body: some Commands {
        CommandMenu("共有") {
            Button("共有設定…") { openWindow(id: "sharing-settings") }
            Divider()
            Button("サーバに接続…") { openWindow(id: "connect") }
            Button("オフライン（ダウンロード済み）…") { openWindow(id: "offline") }
        }
    }
}
