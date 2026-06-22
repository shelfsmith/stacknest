// SPDX-License-Identifier: MIT
import AppKit
import AppCore

/// 4.2c-10: リモート共有サーバを稼働させる前に著作権警告を出す。
/// 抑制済み(AppPreferences.sharingWarningSuppressed)なら即 start。
/// 同意「公開する」で start＋suppression 反映。キャンセルは何もしない（OFF のまま）。
@MainActor enum SharingWarning {
    static func confirmThenStart(_ server: ServerController) {
        if AppPreferences.sharingWarningSuppressed {
            server.start()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "リモート共有の前にご確認ください"
        alert.informativeText = """
        StackNest のリモート共有は個人利用向けの機能です。あなたに著作権のないコンテンツ\
        （市販の漫画・書籍など）を不特定多数がアクセスできる形で公開すると、著作権法上の\
        公衆送信可能化権の侵害となるおそれがあります。共有は信頼できる範囲（家庭内・自分の\
        デバイス間）に限定し、ポートを直接インターネットに公開せず Tailscale などの VPN 経由で\
        ご利用ください。
        """
        alert.addButton(withTitle: "公開する")    // .alertFirstButtonReturn
        alert.addButton(withTitle: "キャンセル")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "今後表示しない"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }   // キャンセル → 何もしない
        if alert.suppressionButton?.state == .on {
            AppPreferences.sharingWarningSuppressed = true
        }
        server.start()
    }
}
