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
    private static var cached: LibrarySettings?

    /// 共有インスタンス。初回アクセス時に DB を開いて（必要なら作成して）マイグレートする。
    /// 失敗時はインメモリ DB にフォールバックする（設定は永続化されないが UI は動作する）。
    static var shared: LibrarySettings {
        if let cached { return cached }
        let settings = makeSettings()
        cached = settings
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
            return try LibrarySettings(database: db)
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

    var body: some View {
        Group {
            if let state {
                RemoteLibraryView(state: state, settings: RemoteLibrarySettingsProvider.shared)
            } else if notFound {
                missingView
            } else {
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .task { await resolve() }
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
    }
}
