// SPDX-License-Identifier: MIT
import AppCore
import LibraryServerAPI
import RemoteClient
import SwiftUI

/// Phase 4.2b-1 fixup v1: 専用「サーバに接続」ウィンドウ（id "connect"）の全フローを内包するビュー。
/// 接続フォーム + 履歴 → 接続成功時に共有ライブラリ数に応じて
/// (0件) インラインメッセージ / (1件) 直接ウィンドウを開く / (2件以上) 同一ウィンドウ内ピッカー
/// を提示する。タイトルウィンドウを開かずに完結する（A1）。
struct RemoteConnectFlowView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// 複数ライブラリ選択待ちの状態。nil の間は接続フォームを表示。
    @State private var picker: PickerState?
    /// 共有ライブラリが 0 件だった場合のインラインメッセージ（G2）。
    @State private var emptyMessage: String?

    private struct PickerState: Identifiable {
        let id = UUID()
        let serverID: UUID
        let libraries: [LibraryDTO]
    }

    var body: some View {
        Group {
            if let picker {
                libraryPicker(picker)
            } else {
                connectForm
            }
        }
        .frame(width: 460)
    }

    // MARK: - 接続フォーム

    private var connectForm: some View {
        ConnectFormView(emptyMessage: emptyMessage) { conn, libs in
            handleConnected(conn: conn, libs: libs)
        }
    }

    /// 接続成功時のハンドラ。共有ライブラリ数で分岐する。
    private func handleConnected(conn: ServerConnection, libs: [LibraryDTO]) {
        if libs.isEmpty {
            emptyMessage = "このサーバで共有中のライブラリがありません"
        } else if libs.count == 1 {
            emptyMessage = nil
            openWindow(value: RemoteLibraryRef(serverID: conn.id, libraryUUID: libs[0].id))
            dismiss()
        } else {
            emptyMessage = nil
            picker = PickerState(serverID: conn.id, libraries: libs)
        }
    }

    // MARK: - ライブラリピッカー（複数共有時）

    @ViewBuilder
    private func libraryPicker(_ p: PickerState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ライブラリを選択").font(.headline)
            List(p.libraries, id: \.id) { lib in
                HStack {
                    Image(systemName: lib.locked ? "lock.fill" : "books.vertical")
                    VStack(alignment: .leading) {
                        Text(lib.name)
                        Text("\(lib.bookCount) 件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("開く") {
                        openWindow(value: RemoteLibraryRef(serverID: p.serverID, libraryUUID: lib.id))
                        dismiss()
                    }
                }
            }
            .frame(height: 200)
            HStack {
                Spacer()
                Button("戻る") { picker = nil }
                Button("閉じる") { dismiss() }
            }
        }
        .padding(20)
    }
}

// MARK: - ConnectFormView

/// 接続フォーム本体（URL+トークン+任意のサーバ名）と接続履歴。
/// 成功時は `onConnected` で報告するだけで dismiss しない（親がフローを制御するため）。
/// ConnectServerSheet の後継で、A6（履歴削除ボタン）/ サーバ名編集 / G2 を取り込む。
struct ConnectFormView: View {
    /// 親が表示するインラインメッセージ（共有 0 件時など）。
    var emptyMessage: String?
    var onConnected: (ServerConnection, [LibraryDTO]) -> Void

    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var nameText = ""
    @State private var error: String?
    @State private var connecting = false
    @State private var saved: [ServerConnection] = []
    /// G25b-1r: 改名中のサーバ（nil の間はシートを出さない）。
    @State private var renaming: ServerConnection?
    /// 改名シートの入力欄。
    @State private var renameText = ""
    private let store = ServerConnectionStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 4.2c-3 (A5-2 v3): ウィンドウ名のみ「リモートブラウザ」に統一。コンテンツ見出しは
            // 接続操作を表す「サーバに接続」のまま（ユーザー指定）。
            Text("サーバに接続").font(.headline)
            if !saved.isEmpty {
                Text("接続済みサーバ").font(.subheadline)
                List {
                    ForEach(saved) { conn in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conn.displayName ?? conn.baseURL)
                                Text(conn.baseURL).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("接続") { Task { await connect(saved: conn) } }
                                .disabled(connecting)
                            // A6: 右クリック context menu に加えて、常時見える削除ボタンを追加。
                            Button {
                                store.remove(id: conn.id)
                                saved = store.all()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("この接続先を履歴から削除")
                        }
                        .contextMenu {
                            Button("サーバ名を変更") {
                                renameText = conn.displayName ?? ""
                                renaming = conn
                            }
                            Button("削除", role: .destructive) {
                                store.remove(id: conn.id)
                                saved = store.all()
                            }
                        }
                    }
                }
                .frame(height: 120)
            }
            TextField("サーバ URL（http://host:port/）", text: $urlText).textFieldStyle(.roundedBorder)
            TextField("トークン", text: $tokenText).textFieldStyle(.roundedBorder)
            TextField("サーバ名（任意）", text: $nameText).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let emptyMessage { Text(emptyMessage).foregroundStyle(.secondary).font(.caption) }
            HStack {
                Spacer()
                Button(connecting ? "接続中…" : "接続") { Task { await connectNew() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || urlText.isEmpty || tokenText.isEmpty)
            }
        }
        .padding(20)
        .onAppear { saved = store.all() }
        .sheet(item: $renaming) { conn in renameSheet(conn) }
    }

    /// G25b-1r: 接続済みサーバの表示名を変更するシート。
    private func renameSheet(_ conn: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("サーバ名を変更").font(.headline)
            Text(conn.baseURL).font(.caption).foregroundStyle(.secondary)
            TextField("サーバ名（空欄でホスト名に戻す）", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("変更") { applyRename(conn) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// 表示名だけを差し替えて upsert する（id 一致で in-place 更新されるため token/URL は保持される）。
    private func applyRename(_ conn: ServerConnection) {
        var updated = conn
        updated.displayName = ServerConnection.normalizedDisplayName(
            input: renameText, host: URL(string: conn.baseURL)?.host)
        store.upsert(updated)
        saved = store.all()
        renaming = nil
    }

    @MainActor private func connectNew() async {
        guard let base = URL(string: urlText) else { error = "URL が不正です"; return }
        connecting = true
        defer { connecting = false }
        // サーバ名: 入力があればそれを、なければ host にフォールバック（改名と同一規則）。
        let displayName = ServerConnection.normalizedDisplayName(input: nameText, host: base.host)
        await attempt(
            ServerConnection(id: UUID(), displayName: displayName, baseURL: urlText, token: tokenText),
            base: base)
    }

    @MainActor private func connect(saved conn: ServerConnection) async {
        guard let base = URL(string: conn.baseURL) else { error = "URL が不正です"; return }
        connecting = true
        defer { connecting = false }
        await attempt(conn, base: base)
    }

    @MainActor private func attempt(_ conn: ServerConnection, base: URL) async {
        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
        do {
            _ = try await client.serverInfo()
            let libs = try await client.listLibraries()
            store.upsert(conn)
            saved = store.all()
            onConnected(conn, libs)
        } catch {
            self.error = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? RemoteClientError {
            return RemoteLibraryState.message(for: e)
        }
        return "接続に失敗しました"
    }
}
