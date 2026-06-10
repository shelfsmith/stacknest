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

    var port: Int { ServerPreferences.port() }
    var token: String { ServerPreferences.token() }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        let config = LibraryServerConfig(port: ServerPreferences.port(), token: ServerPreferences.token())
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
        serverTask?.cancel()   // ServiceLifecycle の graceful shutdown が走る
        serverTask = nil
        isRunning = false
    }

    func regenerateToken() {
        ServerPreferences.regenerateToken()
        // 稼働中なら新トークンを反映するため再起動
        if isRunning { stop(); start() }
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
