// SPDX-License-Identifier: MIT
import AppCore
import LibraryServerAPI
import RemoteClient
import SwiftUI

/// Phase 4.2b-1: サーバ接続シート。URL+トークンで接続し、共有ライブラリ一覧を取得する。
struct ConnectServerSheet: View {
    var onConnected: (ServerConnection, [LibraryDTO]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var error: String?
    @State private var connecting = false
    @State private var saved: [ServerConnection] = []
    private let store = ServerConnectionStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        }
                        .contextMenu {
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
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button(connecting ? "接続中…" : "接続") { Task { await connectNew() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || urlText.isEmpty || tokenText.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { saved = store.all() }
    }

    @MainActor private func connectNew() async {
        guard let base = URL(string: urlText) else { error = "URL が不正です"; return }
        connecting = true
        defer { connecting = false }
        await attempt(
            ServerConnection(id: UUID(), displayName: base.host, baseURL: urlText, token: tokenText),
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
            onConnected(conn, libs)
            dismiss()
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
