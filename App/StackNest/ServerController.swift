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
    /// 直近の起動エラー分類（UI がダイアログ判定に使う）。成功/停止で nil。
    private(set) var startError: ServerStartError?
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
        startError = nil
        // B2: 既存 token/editToken を既定グラント(read/all, edit/all)へ移行（冪等）。
        GrantStore.migrateIfNeeded(readToken: ServerPreferences.token(),
                                   editToken: ServerPreferences.editToken(), now: Date())
        // 既定グラントのトークンを現在値へ同期（トークン再生成/編集トークン無効化を反映＝旧トークン失効）。
        GrantStore.syncDefaultGrants(readToken: ServerPreferences.token(),
                                     editToken: ServerPreferences.editToken(), now: Date())
        // B2b: ヘッドレス起動の最初の admin を env から投入（GUI はローカルコントロール=admin で足りる）。
        if let adminToken = ProcessInfo.processInfo.environment["STACKNEST_ADMIN_TOKEN"], !adminToken.isEmpty {
            let existing = GrantStore.list().first { $0.label == "(env) admin" }
            let g = Grant(id: existing?.id ?? UUID().uuidString, label: "(env) admin", token: adminToken,
                          tier: .admin, scope: .all, createdAt: existing?.createdAt ?? Date())
            if existing != nil { GrantStore.update(g) } else { GrantStore.add(g) }
        }
        let grants = GrantStore.list()
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
            },
            onLibrarySettingsChanged: { uuid in
                // 4.2c-6a (C1'): リモートがスタンプ定義を PUT したら、同バンドルを開いている
                // ローカル AppState のインメモリ設定を DB から再読込してライブ反映する。
                // 4.2c-8: ラベルカスタマイズ（custom_field_labels / custom_book_type_labels）の
                // リモート PUT もここでローカルへ即反映する。
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        state.librarySettings?.reloadStampDefinitions()
                        state.librarySettings?.reloadCustomLabels()
                    }
                }
            },
            onLibraryStructureChanged: { uuid in
                // 4.2d-2: リモート RW での add/delete（行集合の変化）を該当ライブラリへ全リロード反映。
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        try? state.refreshDisplayedBooks()
                    }
                }
            },
            grants: grants   // B2: ネットワーク共有は grant 解決（tier×scope）。起動時スナップショット
        )
        let core = LibraryServerCore(config: config, dataSource: AppStateLibraryDataSource())
        let app = core.buildApplication()
        isRunning = true
        let portUsed = ServerPreferences.port()
        serverTask = Task {
            do {
                // runService() は ServiceLifecycle 配下で動き、Task.cancel() に応答して
                // graceful shutdown する。ポート使用中などの起動失敗もここで throw される。
                try await app.runService()
            } catch {
                // stop() / restart() による cancel 由来の shutdown も runService() の throw
                // （ServiceGroupError）として現れる。これは正常停止なので、起動失敗（ポート使用中
                // など、cancel を伴わない throw）とだけ区別してエラーを表面化する。
                // cancel 時に classify すると「操作を完了できませんでした(ServiceGroupError)」が
                // lastError に乗り、停止のたびに誤エラー表示されていた（4.2c-10/11 smoke A5）。
                if !Task.isCancelled {
                    await MainActor.run {
                        let classified = ServerStartError.classify(error, port: portUsed)
                        self.startError = classified
                        self.lastError = classified.message
                    }
                }
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
                    name: settings.resolvedName(fallback: state.bundleURL.deletingPathExtension().lastPathComponent),
                    bundleURL: state.bundleURL,
                    db: db,
                    isLocked: settings.lockPasswordHash != nil
                )
            }
        }
    }
}
