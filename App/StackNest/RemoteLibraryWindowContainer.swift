// SPDX-License-Identifier: MIT
import AppCore
import LibraryServerAPI
import RemoteClient
import SwiftUI

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
                RemoteLibraryView(state: state)
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
