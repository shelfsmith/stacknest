// SPDX-License-Identifier: MIT
import AppCore
import Foundation
import LibraryStore
import os
import RemoteClient
import SwiftUI

/// Phase 4.2c-1: リモート閲覧ウィンドウ用の共有 `LibrarySettings`。
///
/// リモートウィンドウはローカルのバンドル DB を持たないため、列構成・列幅などの
/// テーブル表示設定（`RemoteBookTableViewRepresentable` が必要とする）を保持する場所がない。
/// ここでアプリサポート配下の専用 SQLite を 1 つ用意し、全リモートウィンドウで共有する
/// （= 列のオン/オフや列幅がウィンドウ間・再起動間で一貫する）。
@MainActor
enum RemoteLibrarySettingsProvider {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemoteLibrarySettings")

    /// G36 ③ Task 7 レビュー Critical 1: `make()` が返す `LibrarySettings` は
    /// `RemoteLibraryWindowContainer` の `@State` にしか保持されず、`AppState.activeInstances`
    /// には載らない。そのため `applicationWillTerminate` の flush ループ（AppState 経由）が
    /// リモート庫の `columnWidths` / `gridItemSize` に届かなかった（列幅・グリッドサイズドラッグ
    /// 直後の ⌘Q で保存されない退行）。`AppStateRegistry` と同じ流儀（`NSHashTable.weakObjects()`）
    /// で弱参照レジストリを持ち、終了時に一括 flush できるようにする。
    ///
    /// リモート側にはバックアップ経路が無い（`BackupManager` の呼び出しは
    /// `App/StackNest/*.swift` 中どこにも無く、`RemoteLibrarySettingsProvider` の settings.db は
    /// バックアップされない）ため、ローカルの「flush は backup より前」という順序規律は
    /// **リモート側には適用対象が無い**（backup 自体が存在しない）。
    ///
    /// `private` にしない: `make()` はアプリサポート配下の実ファイル（実ユーザーの本物の
    /// settings.db）を直接開くため、テストから `make()` 経由でこのレジストリへ触ると実データを
    /// 汚しかねない。テストは一時ファイルで作った `LibrarySettings` を直接 `registry.add` して
    /// `flushAll()` の実効果だけを検証できるよう、module-internal に留める
    /// （`@testable import` で `App/StackNestTests/` から見える）。
    static let registry = NSHashTable<LibrarySettings>.weakObjects()

    /// G36 Codex レビュー P2: 全リモートウィンドウの `LibrarySettings` は別インスタンスでも
    /// **同じ `settings.db`** を指す（`makeSettings()` が固定パスを開くため）。`make()` が
    /// ウィンドウごとに別インスタンスを返す設計は変えない（ラベルが per-window。上のコメント
    /// 参照）が、`columnWidths` / `gridItemSize` / `windowFrame` の書き込みデバウンサだけは
    /// この 1 つを全インスタンスで共有する。共有しないと、同じキーへの書き込みなのに
    /// coalescing が効かず、flush の実行順（タイマー発火順・`registry.allObjects` の列挙順）
    /// 次第で古いウィンドウの値が新しいウィンドウの値を上書きしうる（ユーザー操作順が
    /// 保証されない ―― G36 ③ が同期書き込みを遅延書き込みに変えたことで持ち込んだ退行）。
    /// 共有すれば `SettingsWriteDebouncer` のキー単位 coalescing により
    /// 「最後に schedule された値」だけが書かれ、ユーザー操作順が復活する。
    private static let sharedWriteDebouncer = SettingsWriteDebouncer()

    /// 開いている全リモートウィンドウの保留中設定書き込みを確定させる。
    /// **アプリ終了時に必ず呼ぶ。** 呼ばないとリモート庫の列幅・グリッドサイズが保存されない
    /// （ローカルの `AppState.closeBundle` / `flushPendingWrites` と同じ理由）。
    static func flushAll() {
        for settings in registry.allObjects {
            settings.flushPendingWrites()
        }
    }

    /// 4.2c-8: リモートウィンドウごとに新しい LibrarySettings を生成する。
    /// ラベル（remoteFieldLabelOverride）はライブラリ固有・サーバ canonical のため、共有インスタンス
    /// だと複数リモートウィンドウで混ざる。各ウィンドウが自分のインスタンスを持つ。列幅・grid 等の
    /// クライアント好みは引き続き settings.db から読む（複数同時ウィンドウの即時共有のみ失われる）。
    /// DB を開いて（必要なら作成して）マイグレートする。失敗時はインメモリ DB にフォールバックする。
    static func make() -> LibrarySettings {
        let settings = makeSettings()
        registry.add(settings)
        return settings
    }

    private static func makeSettings() -> LibrarySettings {
        do {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSup.appendingPathComponent("StackNest/RemoteSettings", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbURL = dir.appendingPathComponent("settings.db")
            let db = FileManager.default.fileExists(atPath: dbURL.path)
                ? try Database.openExisting(at: dbURL)
                : try Database.openFile(at: dbURL, mode: .createOrFail)
            try db.migrate()
            let settings = try LibrarySettings(database: db, writeDebouncer: sharedWriteDebouncer)
            // 4.2c-4: リモートブラウザは上ペインの「スタンプ」未対応（別フェーズ）。旧ビルドで
            // ローカルと設定 DB を共有していた等の歴史的経緯で "stamp" が残っていたら、ここで
            // 一度だけ "browse" に矯正する（リモート UI からは stamp を選べないため通常は到達しない）。
            if settings.topPaneMode == "stamp" { settings.topPaneMode = "browse" }
            return settings
        } catch {
            logger.error("RemoteLibrarySettings: file-backed init failed (\(error.localizedDescription)); falling back to in-memory")
            // フォールバック: インメモリ DB（永続化されないが UI は動作する）。
            // ここも失敗するなら設定機構自体が壊れているので致命的に扱う。
            do {
                let db = try Database.openInMemory()
                try db.migrate()
                return try LibrarySettings(database: db, writeDebouncer: sharedWriteDebouncer)
            } catch {
                fatalError("RemoteLibrarySettings: in-memory fallback failed: \(error)")
            }
        }
    }
}

/// リモートライブラリウィンドウを開くための値型（WindowGroup(for:) のキー）。
/// token は含めない（serverID から ServerConnectionStore で解決する）。
struct RemoteLibraryRef: Codable, Hashable {
    let serverID: UUID
    let libraryUUID: String
}

/// RemoteLibraryRef を解決し、サーバ接続が見つかれば RemoteLibraryView を表示するコンテナ。
struct RemoteLibraryWindowContainer: View {
    let ref: RemoteLibraryRef
    private let store = ServerConnectionStore()

    @State private var state: RemoteLibraryState?
    @State private var notFound = false
    /// #7 (Codex High): この窓の NSWindow。state は非同期 resolve 後に確定するため、
    /// 窓の捕捉と state 確定のどちらが先でも関連付けが漏れないよう保持しておく。
    @State private var hostWindow: NSWindow?
    /// 4.2c-8: per-window LibrarySettings（ラベルはこのウィンドウのサーバ庫由来で上書きする）。
    @State private var settings = RemoteLibrarySettingsProvider.make()

    var body: some View {
        Group {
            if let state {
                RemoteLibraryView(state: state, settings: settings)
            } else if notFound {
                missingView
            } else {
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .background(
            // #7 (Codex High): この窓に state を関連付け、NSWindow.willCloseNotification の
            // グローバル観測（AppDelegate）で確実に registry 除去＋token 破棄できるようにする。
            // SwiftUI の onDisappear は WindowGroup では不確実なため、そちらは補助に留める。
            WindowAccessor { window in
                hostWindow = window
                if let s = state { window.stacknestRemoteState = s }
            }
        )
        .task { await resolve() }
        .onChange(of: state == nil) { _, _ in
            // resolve() が state を確定させた後にも関連付ける（窓捕捉が先だった場合の補完）。
            if let w = hostWindow, let s = state { w.stacknestRemoteState = s }
        }
        .onDisappear {
            // G36 ③ Task 7 レビュー Critical 1: このウィンドウの保留中設定書き込みを確定させる。
            // `windowClosed` の条件分岐（下）とは独立に無条件で呼ぶ ―― 実際の close でなくても
            // 早めに flush すること自体は無害（デバウンスの利得を早めに手放すだけ）で、
            // 「閉じたときだけ」に絞ると #7 と同じ理由で見逃しうる（onDisappear は WindowGroup
            // では不確実）。終端の保証は applicationWillTerminate → flushAll() 側が持つ。
            settings.flushPendingWrites()
            // #7: 主経路は NSWindow.willCloseNotification（AppDelegate）。ここは補助で、
            // 窓が実際に閉じている（`isVisible == false`）ときだけ registry 除去＋token 破棄を行う。
            // Codex High の逆方向回帰（窓以外の view teardown で発火し、開いたままの窓の
            // 認証を消して以後の API 操作が失敗する）を避けるための条件付き。
            guard let s = state else { return }
            let windowClosed = hostWindow.map { !$0.isVisible } ?? true
            if windowClosed {
                RemoteLibraryRegistry.shared.remove(s)
                s.libraryToken = nil
            }
        }
    }

    private var missingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("サーバが見つかりません。再接続してください")
                .font(.headline)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
    }

    @MainActor
    private func resolve() async {
        guard state == nil, notFound == false else { return }
        guard let conn = store.connection(id: ref.serverID),
              let base = URL(string: conn.baseURL) else {
            notFound = true
            return
        }
        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
        // ライブラリのメタデータ（name/locked）は listLibraries から uuid で引く。
        // 失敗（オフライン等）でも閲覧は開始できるよう、フォールバック値で state を作る。
        var name = ref.libraryUUID
        var locked = false
        if let libs = try? await client.listLibraries(),
           let lib = libs.first(where: { $0.id == ref.libraryUUID }) {
            name = lib.name
            locked = lib.locked
        }
        state = RemoteLibraryState(
            client: client,
            serverID: ref.serverID,
            libraryUUID: ref.libraryUUID,
            libraryName: name,
            locked: locked
        )
        // Phase 4.2c-2: このウィンドウ宛ての resume 意図があれば消費し、最初の本一覧
        // ロード成功後に対象本を開かせる（unlock 済みトークンがあれば庫内パス画面をスキップ）。
        if let p = RemoteResumeIntent.shared.take(serverID: ref.serverID, libraryUUID: ref.libraryUUID) {
            if let tk = p.libraryToken { state?.libraryToken = tk }
            state?.pendingOpenBookID = (p.bookID, p.forceResume)
        }
    }
}
