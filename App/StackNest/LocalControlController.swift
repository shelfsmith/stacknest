// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import SwiftUI
import LibraryServer
import AppCore

/// 127.0.0.1 専用のローカル制御エンドポイント（CLI/MCP 用）。ネットワーク共有とは独立。
@Observable
@MainActor
final class LocalControlController {
    static let shared = LocalControlController()
    private(set) var isRunning = false
    private var serverTask: Task<Void, Never>?
    private var portRetries = 0
    private static let maxPortRetries = 2

    func startIfEnabled() {
        guard ServerPreferences.localAutomationEnabled() else { return }
        guard !isRunning else { return }
        let usedPort = ServerPreferences.localControlPort()
        let config = LibraryServerConfig(
            host: "127.0.0.1",
            port: usedPort,
            token: UUID().uuidString,                          // 使い捨て read（誰も使わない）
            editToken: ServerPreferences.localControlToken(),  // CLI が提示する RW
            transcoder: ImageIOTranscoder(),
            defaultPageDirection: ViewerSettings.shared.pageDirection,
            onBookChanged: { uuid, bookID in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        state.handleExternalBookChange(bookID: bookID)
                    }
                    // G8a Task 6: CLI/MCP (LocalControl 発) の変更を共有 EventHub へ橋渡し。
                    ServerController.shared.publishLiveEvent(.bookChanged(library: uuid, bookID: bookID))
                }
            },
            onLibrarySettingsChanged: { uuid in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        // G24: ここは CLI / MCP（ローカルコントロール）経由の設定変更を受ける。
                        // 反映する設定が ServerController 側より少なく漏れていたため揃えた。
                        // ロックの漏れは実害があり、施錠しても servedLibraries() が
                        // isLocked: false を返し続けていた（＝配信上は無施錠のまま）。
                        state.librarySettings?.reloadStampDefinitions()
                        state.librarySettings?.reloadCustomLabels()
                        state.librarySettings?.reloadWatchedFolders()
                        state.reloadFolderWatcher()
                        state.librarySettings?.reloadGeneralSettings()
                        state.librarySettings?.reloadLockSettings()
                    }
                    ServerController.shared.publishLiveEvent(.settingsChanged(library: uuid))
                }
            },
            // G16 A3: resultingItemURL を返す（サーバー側 trashTracker が記録し、restore が
            // それだけを使ってファイルを元へ戻す。クライアント供給パスは使わない＝セキュリティ修正）。
            trashFile: { url in
                var out: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &out)
                return out as URL?
            },
            onLibraryStructureChanged: { uuid in
                Task { @MainActor in
                    for state in AppState.activeInstances.allObjects
                    where state.librarySettings?.libraryUUID == uuid {
                        try? state.refreshDisplayedBooks()
                    }
                    ServerController.shared.publishLiveEvent(.structureChanged(library: uuid))
                }
            },
            apiOnly: true,  // ローカルエンドポイントはアプリ Web UI を載せず API ドキュメント(Redoc)のみ
            adminTier: true, // B1: ローカルコントロール(loopback)= admin。CLI/MCP は add/trash/ロック/グローバル設定が可能
            sweepRuntimeTempOnStartup: true,  // G21 #6-2: 実サーバ起動経路のみ古い temp を掃除
            // G27b Task7: /local/libraries/open,close はローカル制御(127.0.0.1)にのみ生やす。
            // ServerController（共有サーバ）はこのフラグを立てない ―― それが唯一のゲート
            // （詳細は LibraryServerConfig.enableLocalLibraryControl のコメント）。
            enableLocalLibraryControl: true,
            openLibrary: { url in try await Self.openLibrary(at: url) },
            closeLibrary: { uuid in try await Self.closeLibrary(uuid: uuid) }
        )
        let core = LibraryServerCore(config: config, dataSource: AllOpenLibrariesDataSource())
        let app = core.buildApplication()
        isRunning = true
        serverTask = Task {
            do {
                try await app.runService()
            } catch {
                // 起動失敗（ポート競合等）。cancel 由来の正常停止は除外。
                // ポート競合なら別ポートへ再採番して 1〜2 回まで自動リトライ（loopback ランダム高位ポート）。
                if !Task.isCancelled,
                   case .portInUse = ServerStartError.classify(error, port: usedPort),
                   Self.maxPortRetries > 0 {
                    await MainActor.run {
                        guard self.portRetries < Self.maxPortRetries else { self.isRunning = false; return }
                        self.portRetries += 1
                        _ = ServerPreferences.regenerateLocalControlPort()
                        self.isRunning = false
                        self.startIfEnabled()   // 新ポートで再起動
                    }
                    return
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        isRunning = false
        portRetries = 0
    }

    /// 設定変更（有効/無効・トークン再生成）後の再構成。
    /// 旧 serverTask の graceful shutdown（runService の return = ポート解放）を待ってから
    /// 起動し直す。stop(); start() を即時に呼ぶと旧サーバがポート解放前に同ポートへ再 bind して
    /// IOError になる（ServerController.restart() と同じ対策・4.1b smoke A5）。
    func reload() {
        let old = serverTask
        serverTask?.cancel()
        serverTask = nil
        isRunning = false
        portRetries = 0
        Task {   // @MainActor を継承
            _ = await old?.value
            startIfEnabled()
        }
    }

    // MARK: - G27b Task7: ローカル制御からのライブラリ開閉

    /// `POST /local/libraries/open` の実装。既存の GUI ウィンドウ経路（openWindow(value:)）に乗せる
    /// ―― こうすることでロック取得（LibraryOpenLockManager）・初回起動・ウィンドウ再利用・状態復元が
    /// すべて既存のコードパス（StackNestApp.swift の LibraryWindowContainer）で処理される。
    /// 施錠庫でもここでは何もしない（解錠画面が出るだけ・G27c でインライン化済みのためアプリは終了可能）。
    ///
    /// 既に開いている庫（AppState.activeInstances に bundleURL が一致する状態がある）なら、
    /// 新規ウィンドウを開かずその UUID をそのまま返す。
    @MainActor
    static func openLibrary(at url: URL) async throws -> String {
        let standardized = url.standardizedFileURL

        if let existing = AppState.activeInstances.allObjects.first(where: {
            $0.bundleURL.standardizedFileURL.path == standardized.path
        }), let settings = existing.librarySettings {
            return settings.ensureLibraryUUID()
        }

        // ウィンドウを開く前にパスの妥当性を確認する（不正パスで空ウィンドウを開いてから
        // 失敗させない ―― 「存在しない/非対応パスはクリーンに失敗する」という要件のため）。
        do {
            try LibraryBundle(url: standardized).validate()
        } catch {
            throw LocalLibraryControlError.invalidPath(standardized.path)
        }

        guard let openWindowAction = WindowBridge.shared.openWindowAction else {
            // Bridge ウィンドウのマウント前（起動直後のごく短い window）。
            throw LocalLibraryControlError.bridgeUnavailable
        }
        openWindowAction(value: standardized)

        // AppState の生成・librarySettings のロードは非同期
        // （LibraryWindowContainer.openBundleIfNeeded → AppState.openBundle）。
        // LibraryWindowContainer 自身も librarySettings 到達を最大 2.5s ポーリングしているのに倣う。
        for _ in 0..<100 {
            if let match = AppState.activeInstances.allObjects.first(where: {
                $0.bundleURL.standardizedFileURL.path == standardized.path
            }), let settings = match.librarySettings {
                return settings.ensureLibraryUUID()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LocalLibraryControlError.timeout
    }

    /// `POST /local/libraries/close` の実装。該当 UUID のライブラリウィンドウを閉じる。
    /// NSWindow.close() を呼ぶだけで、後片付け（appState?.closeBundle() / ロック解放 /
    /// OpenLibraryRegistry からの登録解除）は StackNestApp.swift の .onDisappear が担う
    /// ―― ユーザーが手動でウィンドウを閉じたときと全く同じ経路（特別扱いを追加しない）。
    @MainActor
    static func closeLibrary(uuid: String) async throws {
        guard let match = AppState.activeInstances.allObjects.first(where: {
            $0.librarySettings?.libraryUUID == uuid
        }) else {
            throw LocalLibraryControlError.notFound
        }
        let path = match.bundleURL.standardizedFileURL.path
        guard let window = NSApp.windows.first(where: {
            $0.stacknestBundleURL?.standardizedFileURL.path == path
        }) else {
            throw LocalLibraryControlError.notFound
        }
        window.close()
    }
}
