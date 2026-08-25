// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import SwiftUI
import LibraryServer
import LibraryServerAPI
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

    /// G27b 最終レビュー Fix2 → Codex 事前レビュー Blocker2: メンテナンスジョブ（整合性フルスキャン
    /// 含む）の唯一の登録先。
    ///
    /// ローカル制御は CLI/MCP（`POST .../integrity/full-scan` 等）と GUI の整合性チェック
    /// ウィンドウの**両方**が同じライブラリに対して起動しうる。加えて `ServerController`（共有
    /// ネットワークサーバ）経由でも同じライブラリに対してスキャンを起動できる ―― Blocker2 で、
    /// この 3 経路のうち `ServerController` だけが独自の `MaintenanceJobRegistry` を持っており
    /// busy 判定が割れていたことが判明した（同じ庫に 2 本のフルスキャンが並走し、片方が確定
    /// させた `damaged` を他方の遅れた `ok` で上書きしうる）。
    ///
    /// 解決として、唯一のインスタンスは `SharedMaintenanceRegistry`（中立の置き場所。理由は
    /// そちらのコメント参照）に hoist した。ここではそれをそのまま公開し、既存の参照
    /// （`LocalControlController.shared.maintenanceRegistry`、`IntegrityWindow`・`AppState` 経由）を
    /// 変更せずに済ませる。（a）`startIfEnabled()` と（b）`ServerController.start()` の両方が
    /// これを `LibraryServerCore` へ注入し、（c）`IntegrityWindow` が直接（プロセス内・HTTP を
    /// 経由せず）参照することで、「busy 判定・進捗・中断」を単一の場所に統一する。
    ///
    /// アプリプロセスの生存中ずっと 1 個だけ存在する（ローカル自動化・共有サーバのいずれも OFF
    /// でも GUI からのスキャンは登録され、ボタンの busy 判定は機能する）。
    var maintenanceRegistry: MaintenanceJobRegistry { SharedMaintenanceRegistry.shared }

    /// 外部レビュー Low 是正: `maintenanceRegistry` と同じ理由で名前付きプロパティとして
    /// 引き上げる ―― `startIfEnabled()` 内の `LibraryServerCore(...)` 呼び出しがこれを参照する
    /// ことで、実サーバを起動しないテストからも「fanout が本当に注入されているか」を検証できる。
    var maintenanceEventFanout: MaintenanceEventFanout { SharedMaintenanceRegistry.fanout }

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
            closeLibrary: { uuid in try await Self.closeLibrary(uuid: uuid) },
            finderTagSyncStatus: { uuid in await Self.finderTagSyncStatus(uuid: uuid) },
            resyncFinderTags: { uuid in await Self.resyncFinderTags(uuid: uuid) },
            setFinderTagSyncField: { uuid, field in await Self.setFinderTagSyncField(uuid: uuid, field: field) }
        )
        // 外部レビュー Low 指摘の是正: `SharedMaintenanceRegistry` のコメントは以前から
        // 「`ServerController`／`LocalControlController` はどちらも `maintenanceRegistry:` と
        // `maintenanceEventFanout:` の両方を注入する」と書いていたが、実際に両方注入していたのは
        // `ServerController` だけで、ここ（`LocalControlController`）は `maintenanceEventFanout:`
        // を渡していなかった。コメントが主張する挙動と実装が食い違ったまま放置される状態そのものが
        // このブランチの最大の回帰（G27b Fix3 の「進捗/完了 SSE が届かない」バグ）を招いた原因なので、
        // 実害が無いからと見送らず実装をコメントに合わせる。
        //
        // 安全性: このコアの `/events` を購読するクライアントは存在しない（ローカル制御の整合性
        // ウィンドウ・CLI・MCP はいずれも `maintenance/status` のポーリングで進捗を見ており、
        // `RemoteLibraryState` のような SSE 購読者はローカル制御には無い）。`EventHub.publish`
        // （`Sources/LibraryServer/EventHub.swift`）は `subscribers` 辞書を走査して該当者にだけ
        // yield するだけで、購読者が 0 件なら for ループは何もせず、バッファリングも保持も一切
        // 行わない ―― 購読されない publish は文字どおりの no-op である。よって
        // `maintenanceEventFanout` を注入しても、このコアの eventHub 経由でイベントが漏れる・
        // 蓄積する副作用は生じない。
        let core = LibraryServerCore(config: config, dataSource: AllOpenLibrariesDataSource(),
                                     maintenanceRegistry: maintenanceRegistry,
                                     maintenanceEventFanout: maintenanceEventFanout)
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
        let indexes = Self.windowIndexesToClose(
            bundleURLs: NSApp.windows.map(\.stacknestBundleURL), bundlePath: path)
        guard !indexes.isEmpty else {
            throw LocalLibraryControlError.notFound
        }
        let windows = NSApp.windows
        for i in indexes where i < windows.count { windows[i].close() }

        guard await Self.waitUntilLibraryClosed(uuid: uuid) else {
            throw LocalLibraryControlError.timeout
        }
    }

    /// 閉じるべき窓の添字を選ぶ。**`NSWindow` を作らずに検証できるよう純粋関数に切り出してある**
    /// （App ターゲットのテストで実 `NSWindow` を作るとテストホストが落ちる）。
    ///
    /// ★ **`first` で 1 個だけ拾ってはいけない。**`stacknestBundleURL`（associated object）は
    /// **窓が閉じても消えず**、`WindowGroup` は窓を保持・再利用するため、一度閉じた庫の窓が
    /// 同じ関連付けを持ったまま `NSApp.windows` に残る。`first` だと 2 回目以降は
    /// **既に閉じた古い窓**を掴んで `close()` が no-op になり、生きている窓は開いたままになる
    /// （2026-08-24 実測: アプリ起動後 1 回目の close だけ効き、2 回目以降は 3/3 で失敗した）。
    /// 一致する窓を**全部**返す。閉じ済みの窓へ `close()` を呼んでも無害。
    nonisolated static func windowIndexesToClose(bundleURLs: [URL?], bundlePath: String) -> [Int] {
        bundleURLs.enumerated().compactMap { index, url in
            url?.standardizedFileURL.path == bundlePath ? index : nil
        }
    }

    /// 庫が本当に閉じたかを待つ。閉じたら true、待ち切れなければ false。
    ///
    /// ★ **確認せずに成功を返していたのが被害を大きくした。**CLI/MCP には「閉じました」と
    /// 表示されるのに庫は開いたままで、呼び出し側は閉じたつもりで次の操作に進む。
    /// `closeBundle()` は `activeInstances` から自分を外すので（`AppState.swift:536`）、
    /// **登録が消えたこと**が「窓が閉じて後始末まで走った」ことの証拠になる。
    static func waitUntilLibraryClosed(uuid: String, attempts: Int = 50) async -> Bool {
        for _ in 0..<attempts {
            let stillOpen = await MainActor.run {
                AppState.activeInstances.allObjects.contains { $0.librarySettings?.libraryUUID == uuid }
            }
            if !stillOpen { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50 × 50ms = 2.5s（open と同じ待ち幅）
        }
        return false
    }

    // MARK: - G39: Finder タグ同期（CLI/MCP からの状態確認と手動再照合）

    /// UUID からアプリが開いている庫の `AppState` を引く。開いていなければ nil。
    @MainActor
    private static func appState(libraryUUID uuid: String) -> AppState? {
        AppState.activeInstances.allObjects.first { $0.librarySettings?.libraryUUID == uuid }
    }

    /// `GET /local/libraries/:uuid/finder-tags` の実装。
    ///
    /// **アプリが持っている値をそのまま映す**（DB から組み直さない）。「施錠中か」
    /// 「走行中か」はアプリ側にしか無い状態で、別経路で再現しようとすると必ずずれる。
    @MainActor
    static func finderTagSyncStatus(uuid: String) -> FinderTagSyncStatusReply? {
        guard let state = appState(libraryUUID: uuid) else { return nil }
        return FinderTagSyncStatusReply(field: state.finderTagSyncField,
                                        running: state.isFinderTagSyncRunning,
                                        locked: state.needsUnlock)
    }

    /// `PUT /local/libraries/:uuid/finder-tags` の実装。
    ///
    /// **`AppState.setFinderTagSyncField` をそのまま呼ぶ**（設定シートの Picker と同じ 1 本）。
    /// 前回同期値の全消しはその先の `FinderTagSyncSetting.update` の中だけで起きる。
    @MainActor
    static func setFinderTagSyncField(uuid: String, field: String?) async -> FinderTagSyncStatusReply? {
        guard let state = appState(libraryUUID: uuid) else { return nil }
        // **待つ**（走行中の同期が止まってから設定が変わる）。待たずに応答を組むと、
        // 変えたつもりの項目ではなく古い項目を返してしまう。
        await state.setFinderTagSyncField(field)
        return FinderTagSyncStatusReply(field: state.finderTagSyncField,
                                        running: state.isFinderTagSyncRunning,
                                        locked: state.needsUnlock)
    }

    /// `POST /local/libraries/:uuid/finder-tags/resync` の実装。
    ///
    /// **メニューの「Finder タグを再照合」と同じ 1 本を呼ぶ**（`trigger: .manual`）。
    /// 施錠ゲートも二重起動の抑止もバナーも、すべてそちらに入っているものがそのまま効く。
    @MainActor
    static func resyncFinderTags(uuid: String) async -> FinderTagResyncReply? {
        guard let state = appState(libraryUUID: uuid) else { return nil }
        let field = state.finderTagSyncField
        return await withCheckedContinuation { continuation in
            let start = state.startFinderTagSync(trigger: .manual) { outcome in
                continuation.resume(returning: FinderTagResyncReply(
                    status: FinderTagSyncStart.started.rawValue,
                    field: field,
                    updatedInLibrary: outcome.updatedInLibrary,
                    updatedInFinder: outcome.updatedInFinder,
                    skippedTags: outcome.skippedTags,
                    skippedBooks: outcome.skippedBooks,
                    indexingDisabledVolumes: outcome.indexingDisabledVolumes,
                    failure: outcome.failure))
            }
            // 始まらなかったときは completion が呼ばれないので、ここで一度だけ返す。
            // 始まったときは completion 側が返すので**ここでは返さない**（二重 resume は crash）。
            if start != .started {
                continuation.resume(returning: FinderTagResyncReply(status: start.rawValue, field: field))
            }
        }
    }
}
