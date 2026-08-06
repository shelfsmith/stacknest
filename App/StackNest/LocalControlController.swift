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

    /// G27b 最終レビュー Fix2: メンテナンスジョブ（整合性フルスキャン含む）の唯一の登録先。
    ///
    /// `LibraryServerCore` は自前で `MaintenanceJobRegistry` を作れるが（`ServerController` は
    /// それでよい）、ローカル制御は CLI/MCP（`POST .../integrity/full-scan` 等）と GUI の
    /// 整合性チェックウィンドウの**両方**が同じライブラリに対して起動しうる。この 1 個の
    /// インスタンスを（a）`startIfEnabled()` が毎回同じものを `LibraryServerCore` へ注入し、
    /// （b）`IntegrityWindow` が直接（プロセス内・HTTP を経由せず）参照することで、
    /// 「busy 判定・進捗・中断」を単一の場所に統一する ―― これが無いと GUI が別経路で
    /// スキャンを開始でき、CLI 側からは `running:false` に見えたまま 2 本目の 31 時間スキャンが
    /// 同じ庫に対して走ってしまう（レビューで確認された実害）。
    ///
    /// `startIfEnabled()`/`stop()`/`reload()`（ローカル制御 HTTP リスナーの起動/停止）とは
    /// **独立**に、アプリプロセスの生存中ずっと 1 個だけ存在する（ローカル自動化が OFF でも
    /// GUI からのスキャンは登録され、ボタンの busy 判定は機能する）。onProgress/onFinished は
    /// no-op ―― ローカル制御の SSE `/events` はこのアプリ内のどこからも購読されていない
    /// （購読するのはリモート共有クライアントのみ。詳細は `LibraryServerCore.init` のコメント）。
    let maintenanceRegistry = MaintenanceJobRegistry(
        onProgress: { _, _, _, _ in },
        onFinished: { _, _, _, _ in }
    )

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
        let core = LibraryServerCore(config: config, dataSource: AllOpenLibrariesDataSource(),
                                     maintenanceRegistry: maintenanceRegistry)
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

    /// レビュー修正（G27b Task7 fixup）: 同一パスへの同時 open 要求の直列化。
    ///
    /// `openLibrary(at:)` はウィンドウが実際に開き `AppState` が `activeInstances` に現れるまで
    /// 最大 2.5s、50ms 刻みで `await Task.sleep` する。その await のたびに MainActor を手放すため、
    /// 待っている間に**同じパスへの 2 本目の open 要求**が来ると、まだ `activeInstances` に
    /// 現れていない（＝「既に開いている」判定に引っかからない）ため `openWindowAction` を
    /// もう一度呼んでしまう。
    ///
    /// 実害の調査結果（Codex レビュー指摘への回答）: **2 つ目の `AppState`・DB・FolderWatcher が
    /// 実際に生成されることは無い。** `LibraryWindowContainer.openBundleIfNeeded()` は
    /// `OpenLibraryRegistry.shared.register(bundleURL)` の判定 → `AppState` 生成 → `openBundle()`
    /// （DB open・`finishOpening()` 内の `activeInstances.add(self)` と `reloadFolderWatcher()` を含む）
    /// まで**内部に `await` を一切含まない**（`register`/`acquire` は同期メソッド、`openBundle()` は
    /// 非 async の `throws` 関数）。Swift の協調スケジューリングでは、suspension point の無い
    /// MainActor 上のコードは他の MainActor Task に横入りされない——つまり 2 つのウィンドウが両方
    /// `.onAppear` で `openBundleIfNeeded()` を起動しても、片方が `register()` から
    /// `reloadFolderWatcher()` まで**丸ごと 1 つの atomic 単位**として先に完走し、
    /// もう一方は起動した時点で必ず `register() == false` を見て `AppState` を作る前に
    /// `dismiss()` する。したがって DB 二重書き込み・監視フォルダの二重取込・二重バックアップは
    /// 起こり得ない——実害はウィンドウが一瞬多重に生成されて畳まれる「ちらつき」のみ。
    ///
    /// とはいえ、この安全性は `openBundleIfNeeded()` 側の実装詳細（内部に await が無いこと）に
    /// 暗黙に依存しており壊れやすいため、ここでも同時 open を明示的に直列化する
    /// ―― 2 本目以降は `openWindowAction` を呼ばず、進行中の 1 本目の結果（Task）を待って
    /// 同じ uuid を返す。
    ///
    /// キーは `standardizedFileURL.path`。`AppState.bundleURL` との一致判定・
    /// `OpenLibraryRegistry` の正規化と同じ基準に揃えている（symlink 解決はしない）。
    /// これ以上厳密な正規化（`resolvingSymlinksInPath()` 等）をここだけに入れると、
    /// 「直列化はされるが `OpenLibraryRegistry` は別物として扱う」という新たな不整合を生むため、
    /// 既存の正規化粒度に意図的に合わせている。
    private static var inFlightOpens: [String: Task<String, Error>] = [:]

    /// テスト専用の注入フック。非 nil ならウィンドウ実体・`WindowBridge` を経由せずこの closure を
    /// 呼ぶ。本番は常に nil。実 `NSWindow` を作れない App-target テストから、`inFlightOpens` による
    /// 直列化ロジック（同一パスへの同時 open が「ウィンドウを開く」動作を 1 回しか起こさないこと）
    /// だけを検証するための唯一の注入点（`App/StackNestTests/LocalControlControllerOpenSerializationTests.swift`）。
    static var testOpenWindowHook: ((URL) -> Void)?

    /// `POST /local/libraries/open` の実装。既存の GUI ウィンドウ経路（openWindow(value:)）に乗せる
    /// ―― こうすることでロック取得（LibraryOpenLockManager）・初回起動・ウィンドウ再利用・状態復元が
    /// すべて既存のコードパス（StackNestApp.swift の LibraryWindowContainer）で処理される。
    /// 施錠庫でもここでは何もしない（解錠画面が出るだけ・G27c でインライン化済みのためアプリは終了可能）。
    ///
    /// 既に開いている庫（AppState.activeInstances に bundleURL が一致する状態がある）なら、
    /// 新規ウィンドウを開かずその UUID をそのまま返す。同一パスへの同時呼び出しは直列化する
    /// （`inFlightOpens` を参照）。
    @MainActor
    static func openLibrary(at url: URL) async throws -> String {
        let standardized = url.standardizedFileURL
        let key = standardized.path

        if let existing = AppState.activeInstances.allObjects.first(where: {
            $0.bundleURL.standardizedFileURL.path == key
        }), let settings = existing.librarySettings {
            return settings.ensureLibraryUUID()
        }

        // 同じパスへの open が既に進行中なら、新規ウィンドウは開かずその結果を待つ。
        // ここから inFlightOpens への読み書きは await を挟まないため、2 本の呼び出しが
        // 「同時」に来ても片方が必ず先に Task を登録し終えてからもう片方が参照する
        // （MainActor 上の非 suspending なコードは横入りされない）。
        if let inFlight = inFlightOpens[key] {
            return try await inFlight.value
        }

        let task = Task<String, Error> { @MainActor in
            defer { inFlightOpens[key] = nil }   // 成功・失敗・タイムアウトいずれでも必ず解放する
            return try await Self.performOpen(at: standardized)
        }
        inFlightOpens[key] = task
        return try await task.value
    }

    /// `openLibrary(at:)` の直列化ラッパから 1 回だけ呼ばれる実体。
    /// パス検証 → openWindowAction → AppState 登録待ちポーリングを行う。
    @MainActor
    private static func performOpen(at standardized: URL) async throws -> String {
        // ウィンドウを開く前にパスの妥当性を確認する（不正パスで空ウィンドウを開いてから
        // 失敗させない ―― 「存在しない/非対応パスはクリーンに失敗する」という要件のため）。
        do {
            try LibraryBundle(url: standardized).validate()
        } catch {
            throw LocalLibraryControlError.invalidPath(standardized.path)
        }

        if let testHook = Self.testOpenWindowHook {
            testHook(standardized)
        } else {
            guard let openWindowAction = WindowBridge.shared.openWindowAction else {
                // Bridge ウィンドウのマウント前（起動直後のごく短い window）。
                throw LocalLibraryControlError.bridgeUnavailable
            }
            openWindowAction(value: standardized)
        }

        // AppState の生成・librarySettings のロードは非同期
        // （LibraryWindowContainer.openBundleIfNeeded → AppState.openBundle）。
        // LibraryWindowContainer 自身も librarySettings 到達を最大 50 回 × 50ms = 2.5s ポーリングして
        // いるのに倣う（同じ待ち幅に揃える）。
        for _ in 0..<50 {
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
