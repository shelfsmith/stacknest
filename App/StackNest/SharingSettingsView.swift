// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 設定「共有」タブ。アプリ内蔵 LibraryServer の起動/停止・ポート・トークン+QR・
/// per-library オプトイン（remoteSharingEnabled）を操作する。
///
/// ServerController.shared は @Observable @MainActor なので、`@State` で保持すれば
/// isRunning / lastError の変化を SwiftUI が追跡して再描画する。
struct SharingSettingsView: View {
    /// @Observable な singleton を観察する。直接 .shared を読むだけでは observation が
    /// 成立しないため、@State に保持して view の dependency に載せる。
    @State private var server = ServerController.shared

    /// 開いているライブラリのレジストリを @State で観察する（4.1b smoke F2）。
    /// body で `registry.allObjects` を読むことで、ライブラリ開閉によるメンバー増減で
    /// このタブが確実に再描画される（旧 NSHashTable 直読みでは再描画されず、配信対象が
    /// 更新されなかった上、閉じたライブラリの dangling 参照でタブ body がクラッシュして
    /// 共有タブ自体が view tree から消えていた）。
    @State private var registry = AppState.activeInstances

    /// ポート編集用のローカル文字列。稼働中は disabled。コミットは onSubmit / Toggle ON 時。
    @State private var portInput: String = String(ServerPreferences.port())

    /// ポート使用不可（起動失敗）アラートの表示制御。
    @State private var showPortInUseAlert = false

    /// 起動時に共有を自動開始するか（ServerPreferences と同一キー）。
    @AppStorage(ServerPreferences.autoStartSharingKey) private var autoStartSharing = false

    /// startError の portInUse 変化を検出するためのトークン。
    private var portInUseToken: String {
        if case .portInUse(let p) = server.startError { return "inuse-\(p)" }
        return "none"
    }

    var body: some View {
        Form {
            serverSection
            if server.isRunning {
                connectionSection
            }
            GrantManagementSection()
            librariesSection
        }
        .formStyle(.grouped)
        .onChange(of: portInUseToken) { _, _ in
            if case .portInUse = server.startError { showPortInUseAlert = true }
        }
        .alert("ポートを使用できません", isPresented: $showPortInUseAlert) {
            Button("別のポートにして再起動") {
                ServerPreferences.setPort(ServerPreferences.randomPort())
                portInput = String(ServerPreferences.port())
                server.start()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(server.startError?.message ?? "")
        }
        .frame(width: 600)
        .background(SettingsWindowFixedSize(
            tabBarPadding: 0,
            tab: 0,
            contentRevision: server.isRunning ? 1 : 0
        ))
    }

    // MARK: - サーバセクション

    @ViewBuilder
    private var serverSection: some View {
        Section("サーバ") {
            Toggle("リモート共有サーバを稼働", isOn: Binding(
                get: { server.isRunning },
                set: { wantRunning in
                    if wantRunning {
                        commitPortIfPossible()
                        SharingWarning.confirmThenStart(server)   // 4.2c-10: 警告→同意で start
                    } else {
                        server.stop()
                    }
                }
            ))

            HStack(spacing: 8) {
                if server.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    // A4: \(Int) を LocalizedStringKey で補間すると桁区切り（"8,724"）に
                    // なるため、String(port) を補間して桁区切りを止める。
                    Text("ポート \(String(server.port)) で配信中")
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)
                    Text("停止中")
                        .foregroundStyle(.secondary)
                }
            }

            if let err = server.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Text("ポート")
                Spacer()
                TextField("", text: $portInput)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(server.isRunning)
                    .onChange(of: portInput) { _, newValue in
                        // 数字以外を弾く + 5 桁（最大 65535）に制限
                        let cleaned = String(newValue.filter(\.isNumber).prefix(5))
                        if cleaned != newValue { portInput = cleaned }
                    }
                    .onSubmit { commitPortIfPossible() }
                Button("ランダム") {
                    guard !server.isRunning else { return }
                    ServerPreferences.setPort(ServerPreferences.randomPort())
                    portInput = String(ServerPreferences.port())
                }
                .disabled(server.isRunning)
                .help("使われにくいポート番号をランダムに設定")
            }
            if server.isRunning {
                Text("ポートは停止中に変更できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ON にする瞬間に既存の共有/著作権警告を通す（同意で ON・キャンセルで OFF のまま）。
            // 抑制済みなら即 ON。自動起動の発火自体は起動時 silent（同意はここで取る）。
            Toggle("起動時に共有を自動で開始する", isOn: Binding(
                get: { autoStartSharing },
                set: { newValue in
                    if newValue {
                        SharingWarning.confirm { autoStartSharing = true }
                    } else {
                        autoStartSharing = false
                    }
                }
            ))
            Text("⚠ 有効にすると、次回以降のアプリ起動時に自動でネットワーク共有を開始します。ライブラリを外部に見せる意味を理解した上で有効にしてください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// ポート入力を検証して永続化する（停止中のみ・1...65535）。
    private func commitPortIfPossible() {
        guard !server.isRunning else { return }
        if let v = Int(portInput), (1...65535).contains(v) {
            ServerPreferences.setPort(v)
        }
        // 無効入力は現値に戻す
        portInput = String(ServerPreferences.port())
    }

    // MARK: - 接続セクション（稼働中のみ）

    @ViewBuilder
    private var connectionSection: some View {
        // IPv4 + IPv6 を en0 優先・IPv4→IPv6 順で取得する。
        let addresses = NetworkInterfaces.addresses()
        Section("接続") {
            if addresses.isEmpty {
                Text("ネットワークアドレスが見つかりません。Wi-Fi / 有線 / Tailscale の接続を確認してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(addresses, id: \.ip) { addr in
                            HStack(spacing: 8) {
                                // A4: verbatim で桁区切りを止める（LocalizedStringKey 補間だと
                                // port が "8,724" のように桁区切りされる）。
                                // IPv6 は displayHost が [...] で囲む。
                                Text(verbatim: "http://\(addr.displayHost):\(server.port)/")
                                    .monospaced()
                                    .textSelection(.enabled)
                                Spacer()
                                Text(addr.interface)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    // MARK: - 配信ライブラリセクション

    @ViewBuilder
    private var librariesSection: some View {
        Section("配信ライブラリ") {
            // registry.allObjects を read することで version dependency に載り、
            // ライブラリ開閉で再描画される。librarySettings が nil（開封中/閉鎖直後）の
            // インスタンスは guard で skip し、dangling Binding を作らない。
            let instances = registry.allObjects.filter { $0.librarySettings != nil }
            if instances.isEmpty {
                Text("ライブラリを開くとここに表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(instances, id: \.bundleURL) { state in
                    if let settings = state.librarySettings {
                        librarySharingRow(state: state, settings: settings)
                    }
                }
            }
        }
    }

    /// 1 ライブラリ分の共有 Toggle 行。
    /// LibrarySettings は @Observable な class なので Binding(get:set:) で remoteSharingEnabled
    /// を読み書きすると didSet で DB 永続化（Task 3）＋ SwiftUI 再描画が同時に成立する。
    /// 稼働中サーバは dataSource を毎リクエスト呼ぶ設計（4.1a）のため、次のリクエストから反映される。
    @ViewBuilder
    private func librarySharingRow(state: AppState, settings: LibrarySettings) -> some View {
        Toggle(isOn: Binding(
            get: { settings.remoteSharingEnabled },
            set: { settings.remoteSharingEnabled = $0 }
        )) {
            HStack(spacing: 6) {
                Text(state.bundleURL.deletingPathExtension().lastPathComponent)
                if settings.lockPasswordHash != nil {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("ロック庫")
                }
            }
        }
    }

}
