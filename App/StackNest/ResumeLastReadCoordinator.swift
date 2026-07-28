// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore
import RemoteClient

@MainActor
enum ResumeLastReadCoordinator {
    /// ⌘⇧O 実行。アプリ全体の直近 1 冊を最終ページで開く。記録が無ければ no-op。
    static func resume(openWindow: OpenWindowAction) async {
        guard let last = LastReadTracker.shared.last else { return }
        switch last {
        case .offline(let bookID, _):
            OfflineResumeIntent.shared.pendingBookID = bookID
            openWindow(id: "offline")
            // 既にオフラインウィンドウが開いている場合、openWindow はフォーカスするだけで
            // .task { reload() } を再実行しない。通知で live な OfflineLibraryView に reload() を
            // 促し、pendingBookID を消費させる（リモートの already-open と同種のバグ対策）。
            NotificationCenter.default.post(name: .offlineResumeRequested, object: nil)

        case .local(let bundlePath, let bookID, _):
            // 既に開いていれば直接開く。bundleURL は非 optional。
            // try? + optional-chaining は二重 Optional を平坦化し BookRow? を返すため単一バインドで足りる。
            if let st = AppState.activeInstances.allObjects.first(where: { $0.bundleURL.path == bundlePath }),
               let book = try? st.database?.fetchBook(id: bookID) {
                // #7: 施錠ライブラリは resumeDirect でロックを迂回しない。ただし既にこのウィンドウで
                // 解錠済みなら再認証は求めない（.remote 経路と同一規則＝ResumeGate に一本化）。
                switch ResumeGate.decide(isLocked: st.librarySettings?.lockPasswordHash != nil,
                                         isUnlocked: st.isUnlocked) {
                case .openBook:
                    st.openBooks([book], resumeDirect: true)
                case .deferUntilUnlock:
                    // 解錠ゲートが出るので、解錠に成功した時点で開くよう保留する。
                    st.pendingResumeBookID = bookID
                    openWindow(value: URL(fileURLWithPath: bundlePath))   // フォーカス（解錠ゲートが出る）
                }
            } else {
                LocalResumeIntent.shared.pending = (bundlePath, bookID)
                openWindow(value: URL(fileURLWithPath: bundlePath))
            }

        case .remote(let serverID, _, let libraryUUID, _, let bookID, _, let locked):
            // 既に開いているリモートウィンドウがあれば、そこで直接開く（pending を消費しない経路）。
            if let st = RemoteLibraryRegistry.shared.allObjects.first(where: {
                $0.serverID == serverID && $0.libraryUUID == libraryUUID
            }) {
                openWindow(value: RemoteLibraryRef(serverID: serverID, libraryUUID: libraryUUID)) // フォーカス
                // #7: 既に開いているウィンドウが認証済み（非施錠 or library token 取得済み）なら、
                // ユーザーは既にそのライブラリを解錠して閲覧中なので resume を再認証なしで受け入れる。
                // G25b-1r: 判定はローカル経路と同一の ResumeGate に通す（従来の
                // `!st.locked || st.libraryToken != nil` と等価＝挙動は変わらない）。
                switch ResumeGate.decide(isLocked: st.locked, isUnlocked: st.libraryToken != nil) {
                case .openBook:
                    await st.openBookByID(bookID, resumeDirect: true)
                case .deferUntilUnlock:
                    // 施錠かつ未認証（ウィンドウを閉じて token 無効化済み）: 本は直接開かず解錠を促す。
                    // 解錠後（unlock → reload）に対象本が開くよう pending を積む
                    // （バイパスは防ぎつつ、解錠さえすれば従来どおり続きから開く）。
                    st.pendingOpenBookID = (bookID, true)
                }
                return
            }
            let store = ServerConnectionStore()
            guard let conn = store.connection(id: serverID), let base = URL(string: conn.baseURL) else {
                presentInfo("最後に開いた本のサーバ接続が見つかりません。「共有 → サーバに接続」で接続してから再度実行してください。")
                return
            }
            // #7: 施錠リモートライブラリの resume はロックを迂回しない。以前はセッション内で unlock
            // トークンを unlockTokens にキャッシュして再プロンプトを省いていたが、ライブラリを閉じても
            // トークンが残り「ライブラリは解錠要求されるのに本だけパスワード無しで開く」バイパスになっていた。
            // resume では常に解錠を要求する（ウィンドウが既に開いている＝解錠済みの場合は上の
            // early-return 枝で扱われるため、ここに来る時点でライブラリは開いていない＝再解錠が正しい）。
            var token: String? = nil
            if locked {
                guard let pw = promptPassword() else { return }   // キャンセルで中止
                let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
                do {
                    token = try await client.unlock(libraryUUID: libraryUUID, password: pw)
                } catch {
                    presentInfo("解錠に失敗しました（パスワードを確認してください）。")
                    return
                }
            }
            RemoteResumeIntent.shared.pending = PendingRemoteOpen(
                serverID: serverID, libraryUUID: libraryUUID, bookID: bookID,
                libraryToken: token, forceResume: true)
            openWindow(value: RemoteLibraryRef(serverID: serverID, libraryUUID: libraryUUID))
        }
    }

    /// NSAlert＋セキュア入力でパスワードを尋ねる。OK→文字列、キャンセル→nil。
    private static func promptPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "ライブラリのパスワード"
        alert.informativeText = "最後に開いた本のライブラリは保護されています。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "解錠")
        alert.addButton(withTitle: "キャンセル")
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue
        return v.isEmpty ? nil : v
    }

    private static func presentInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "最後に開いたページ"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
