// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryServer

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

    /// トークン再生成の確認ダイアログ。
    @State private var showRegenerateConfirm = false

    /// 編集トークン再生成の確認ダイアログ。
    @State private var showRegenerateEditTokenConfirm = false

    /// 編集トークン無効化の確認ダイアログ。
    @State private var showClearEditTokenConfirm = false

    /// QR に使う接続先 IP アドレス。nil のとき addresses.first を使う。
    @State private var selectedHostIP: String?

    /// ポート使用不可（起動失敗）アラートの表示制御。
    @State private var showPortInUseAlert = false

    /// LocalControlController を @State で保持して observation に載せる。
    @State private var localControl = LocalControlController.shared

    /// ローカル自動化 Toggle / 再生成 後の body 再評価用トークン。
    @State private var localControlRefresh = UUID()

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
            tokenSection
            editTokenSection
            librariesSection
            localAutomationSection
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

                // アドレスが 2 件以上あるとき、QR に使う IP を選択できる Picker を表示する。
                // nil のとき先頭にフォールバックして表示する（@State は書き換えない）。
                if addresses.count >= 2 {
                    Picker("接続先", selection: Binding(
                        get: { selectedHostIP ?? addresses.first?.ip },
                        set: { selectedHostIP = $0 }
                    )) {
                        ForEach(addresses, id: \.ip) { addr in
                            Text("\(addr.interface) — \(addr.displayHost)")
                                .tag(Optional(addr.ip))
                        }
                    }
                }

                // 選択 IP に一致するアドレス、無ければ addresses.first を使う。
                let chosen = addresses.first(where: { $0.ip == selectedHostIP }) ?? addresses.first
                if let chosen {
                    VStack(spacing: 8) {
                        // PairingInfo.url に生 IP を渡す（PairingInfo 側が IPv6 を [...] で囲む）。
                        QRCodeView(
                            content: PairingInfo.url(host: chosen.ip, port: server.port, token: server.token),
                            size: 160
                        )
                        Text("接続先: \(chosen.interface) — \(chosen.displayHost)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("iPhone のカメラで読み取ると Safari が開き自動でペアリングされます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            // 保存済みの IP 選択を復元する。
            selectedHostIP = ServerPreferences.preferredHostIP()
        }
        .onChange(of: selectedHostIP) { _, newValue in
            ServerPreferences.setPreferredHostIP(newValue)
        }
    }

    // MARK: - トークンセクション

    @ViewBuilder
    private var tokenSection: some View {
        Section("アクセストークン") {
            Text(server.token)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.token, forType: .string)
                }

                Button("再生成…") {
                    showRegenerateConfirm = true
                }
            }
            .confirmationDialog(
                "トークンを再生成しますか？",
                isPresented: $showRegenerateConfirm,
                titleVisibility: .visible
            ) {
                Button("再生成", role: .destructive) {
                    server.regenerateToken()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("既存のペアリング端末は再ペアリングが必要になります。")
            }
        }
    }

    // MARK: - 編集用トークンセクション（RW）

    @ViewBuilder
    private var editTokenSection: some View {
        Section("編集用トークン（RW）") {
            if let editToken = server.editToken {
                // トークン発行済み: 表示・コピー・再生成・無効化
                Text(editToken)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editToken, forType: .string)
                    }

                    Button("再生成…") {
                        showRegenerateEditTokenConfirm = true
                    }
                    .confirmationDialog(
                        "編集用トークンを再生成しますか？",
                        isPresented: $showRegenerateEditTokenConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("再生成", role: .destructive) {
                            server.regenerateEditToken()
                        }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("既存の編集クライアントは再ペアリングが必要になります。")
                    }

                    Button("無効化（クリア）…", role: .destructive) {
                        showClearEditTokenConfirm = true
                    }
                    .confirmationDialog(
                        "編集用トークンを無効化しますか？",
                        isPresented: $showClearEditTokenConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("無効化", role: .destructive) {
                            server.clearEditToken()
                        }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("リモート編集が無効になります。再度発行するまで編集クライアントは接続できません。")
                    }
                }

                Text("⚠ 編集用トークンは編集を許可します。自分・信頼できる相手にのみ渡してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // トークン未発行: 説明と発行ボタン
                Text("編集用トークンを発行すると、そのトークンで接続したクライアントが本のメタデータを編集できます（閲覧用トークンは読み取り専用のまま）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("編集用トークンを発行") {
                    server.regenerateEditToken()
                }
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

    // MARK: - ローカル自動化セクション（CLI / MCP）

    @ViewBuilder
    private var localAutomationSection: some View {
        // localControlRefresh を body で読むことで、Toggle/再生成後の UUID 更新で再評価される。
        let _ = localControlRefresh
        Section("ローカル自動化（CLI / MCP）") {
            Toggle("ローカル自動化を許可（127.0.0.1）", isOn: Binding(
                get: { ServerPreferences.localAutomationEnabled() },
                set: { on in
                    ServerPreferences.setLocalAutomationEnabled(on)
                    localControl.reload()
                    localControlRefresh = UUID()
                }))
            if ServerPreferences.localAutomationEnabled() {
                HStack {
                    Circle()
                        .fill(localControl.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(localControl.isRunning ? "稼働中（127.0.0.1）" : "停止中")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("ポート")
                    Spacer()
                    Text(String(ServerPreferences.localControlPort())).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Text("トークン")
                    Spacer()
                    Text(ServerPreferences.localControlToken())
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ServerPreferences.localControlToken(), forType: .string)
                    }
                    Button("再生成") {
                        _ = ServerPreferences.regenerateLocalControlToken()
                        localControl.reload()
                        localControlRefresh = UUID()
                    }
                }
                Text("同じ Mac の CLI `stacknest` は自動接続します。ネットワークには公開されません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
