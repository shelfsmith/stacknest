// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import LibraryServer
import AppCore

/// アプリ内蔵サーバのライフサイクル管理（設定「共有」タブから操作）。
/// 配信対象 = 開いている ∧ remoteSharingEnabled なライブラリ（AppStateLibraryDataSource）。
@Observable
@MainActor
final class ServerController {
    static let shared = ServerController()

    private(set) var isRunning = false
    private(set) var lastError: String?
    private var serverTask: Task<Void, Never>?

    /// ライフサイクル世代カウンタ。stop() / restart() のたびにインクリメントする。
    /// restart() は await 中に手動 stop（共有トグル OFF）や別 restart が割り込むと、
    /// resume 後の start() が「OFF にしたのに復活」を引き起こすため、開始時の世代を記録し、
    /// await 後に最新世代と一致するときだけ start() する。
    private var lifecycleGeneration = 0

    var port: Int { ServerPreferences.port() }
    var token: String { ServerPreferences.token() }
    /// 編集（RW）トークン。未生成は nil（その場合リモート編集は不可・R のみ）。
    /// @Observable の stored property にすることで、サーバ停止中に発行/クリアしても共有設定 UI が
    /// 即時更新される（A2 修正: computed だと稼働中の restart で observed prop が変わらない限り
    /// 再描画されず「サーバ OFF で発行ボタン無反応」に見えた）。
    private(set) var editToken: String? = ServerPreferences.editToken()

    func start() {
        guard !isRunning else { return }
        lastError = nil
        let config = LibraryServerConfig(
            host: "::",                      // dual-stack（IPv4/IPv6 両対応）
            port: ServerPreferences.port(),
            token: ServerPreferences.token(),
            editToken: ServerPreferences.editToken(),
            transcoder: ImageIOTranscoder(),
            defaultPageDirection: ViewerSettings.shared.pageDirection,   // サーバ起動時スナップショット（4.1c）
            onBookChanged: { uuid, bookID in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        state.handleExternalBookChange(bookID: bookID)
                    }
                }
            }
        )
        let core = LibraryServerCore(config: config, dataSource: AppStateLibraryDataSource())
        let app = core.buildApplication()
        isRunning = true
        serverTask = Task {
            do {
                // runService() は ServiceLifecycle 配下で動き、Task.cancel() に応答して
                // graceful shutdown する。ポート使用中などの起動失敗もここで throw される。
                try await app.runService()
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    func stop() {
        lifecycleGeneration &+= 1   // 進行中の restart を陳腐化させる
        serverTask?.cancel()   // ServiceLifecycle の graceful shutdown が走る
        serverTask = nil
        isRunning = false
    }

    func regenerateToken() {
        ServerPreferences.regenerateToken()
        // 稼働中なら新トークンを反映するため再起動
        if isRunning { restart() }
    }

    /// 編集（RW）トークンを生成/再生成する。稼働中なら新トークン反映のため再起動（4.2b-3）。
    func regenerateEditToken() {
        editToken = ServerPreferences.regenerateEditToken()   // stored prop 更新で UI 即反映（A2）
        if isRunning { restart() }
    }

    /// 編集（RW）トークンを削除（リモート編集を無効化）。稼働中なら反映のため再起動（4.2b-3）。
    func clearEditToken() {
        ServerPreferences.clearEditToken()
        editToken = nil
        if isRunning { restart() }
    }

    /// 稼働中の再起動。旧 serverTask の graceful shutdown（runService の return = ポート解放）
    /// を待ってから start() する。stop(); start() を即時に呼ぶと、旧サーバがポートを解放する前に
    /// 同ポートへ再 bind して IOError になっていた（4.1b smoke A5）。
    private func restart() {
        let old = serverTask
        lifecycleGeneration &+= 1
        let gen = lifecycleGeneration   // この restart の世代を記録
        serverTask?.cancel()
        serverTask = nil
        isRunning = false
        Task {   // ServerController は @MainActor なので MainActor を継承する
            // runService() が完全に return = ポート解放完了まで待ってから再起動する。
            _ = await old?.value
            // await 中に手動 stop / 別 restart が割り込んでいたら世代が進んでいる。
            // その場合は再起動を覆さないよう start() をスキップする。
            guard gen == lifecycleGeneration else { return }
            start()
        }
    }
}

/// 「現在開いている ∧ リモート共有 ON」のライブラリを ServedLibrary に変換する。
/// LibraryServerDataSource は任意 executor から呼ばれるため、MainActor へホップして
/// activeInstances / librarySettings を読む。
struct AppStateLibraryDataSource: LibraryServerDataSource {
    func servedLibraries() async -> [ServedLibrary] {
        await MainActor.run {
            AppState.activeInstances.allObjects.compactMap { state in
                guard let db = state.database,
                      let settings = state.librarySettings,
                      settings.remoteSharingEnabled else { return nil }
                let uuid = settings.ensureLibraryUUID()
                return ServedLibrary(
                    uuid: uuid,
                    name: state.bundleURL.deletingPathExtension().lastPathComponent,
                    bundleURL: state.bundleURL,
                    db: db,
                    isLocked: settings.lockPasswordHash != nil
                )
            }
        }
    }
}
