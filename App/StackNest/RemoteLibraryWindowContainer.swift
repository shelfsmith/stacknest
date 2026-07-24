// SPDX-License-Identifier: MIT
import AppCore
import Foundation
import LibraryServerAPI
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

    /// 4.2c-8: リモートウィンドウごとに新しい LibrarySettings を生成する。
    /// ラベル（remoteFieldLabelOverride）はライブラリ固有・サーバ canonical のため、共有インスタンス
    /// だと複数リモートウィンドウで混ざる。各ウィンドウが自分のインスタンスを持つ。列幅・grid 等の
    /// クライアント好みは引き続き settings.db から読む（複数同時ウィンドウの即時共有のみ失われる）。
    /// DB を開いて（必要なら作成して）マイグレートする。失敗時はインメモリ DB にフォールバックする。
    static func make() -> LibrarySettings {
        makeSettings()
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
            let settings = try LibrarySettings(database: db)
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
                return try LibrarySettings(database: db)
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
        .task { await resolve() }
        .onDisappear {
            // #7: ウィンドウを閉じたら registry から外し、認証（library token）も無効化する。
            // RemoteLibraryState は SwiftUI の @State/Task 保持で閉鎖後も生き残ることがあり、
            // registry に残ると ⌘⇧O（resume）の already-open 枝がそれを「開いている」と誤認する。
            // すると reopen が作る新 state と食い違い、(a) 施錠庫の本を解錠なしで開く（バイパス）、
            // (b) 解錠しても本が開かない（pending を古い state に積む）等の不整合が出ていた。
            // 外せば閉じた庫は cold path（NSAlert 解錠→新ウィンドウで続きを開く＝アプリ再起動時と
            // 同じ挙動）に落ちる。開いたままなら onDisappear は発火せず認証を維持する。
            if let s = state {
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
