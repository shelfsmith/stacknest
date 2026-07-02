// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryServer
import LibraryServerAPI

/// サーバ設定窓の「グラント」セクション。カスタムグラント（既定 R/RW・env-admin 以外）を
/// 一覧・追加・編集・削除・トークン再生成する。GrantStore を直接操作し、C-③a のライブ解決で
/// 稼働中サーバへ即反映（再起動不要）。GrantStore は非 Observable のため @State に読み込み直す。
struct GrantManagementSection: View {
    @State private var grants: [Grant] = []
    @State private var editorTarget: GrantEditorTarget?
    @State private var pendingDelete: Grant?
    @State private var pendingRegenerate: Grant?
    @State private var server = ServerController.shared
    @State private var qrTarget: Grant?

    var body: some View {
        Section("共有トークン") {
            let custom = GrantManagementLogic.customGrants(grants)
            if custom.isEmpty {
                Text("共有トークンを追加すると、相手ごとに見せるライブラリと権限を分けられます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(custom) { grant in
                    grantRow(grant)
                }
            }
            Button("＋ 共有トークンを追加") { editorTarget = .create }
        }
        .onAppear(perform: reload)
        .sheet(item: $editorTarget) { target in
            GrantEditorSheet(target: target, onSaved: reload)
        }
        .sheet(item: $qrTarget) { grant in
            GrantQRSheet(grant: grant, port: server.port)
        }
        .confirmationDialog("グラントを削除しますか？", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let d = pendingDelete { GrantStore.delete(id: d.id); reload() }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このグラントを削除すると、そのトークンでの接続は直ちにできなくなります（取り消し不可）。")
        }
        .confirmationDialog("トークンを再生成しますか？", isPresented: regenerateBinding, titleVisibility: .visible) {
            Button("再生成", role: .destructive) {
                if var r = pendingRegenerate {
                    r.token = ServerPreferences.generateToken()
                    GrantStore.update(r)
                    reload()
                }
                pendingRegenerate = nil
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この許可証の既存接続は再ペアリングが必要になります。")
        }
    }

    private func reload() { grants = GrantStore.list() }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
    private var regenerateBinding: Binding<Bool> {
        Binding(get: { pendingRegenerate != nil }, set: { if !$0 { pendingRegenerate = nil } })
    }

    @ViewBuilder
    private func grantRow(_ grant: Grant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(grant.label).fontWeight(.medium)
                tierBadge(grant.tier)
                Spacer()
                Text(GrantManagementLogic.scopeSummary(grant.scope))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(scopeHelp(grant.scope))
            }
            Text(grant.token)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("QR") { qrTarget = grant }
                    .disabled(!server.isRunning)
                    .help(server.isRunning ? "この共有トークンの QR を表示" : "サーバ稼働中のみ")
                Button("コピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(grant.token, forType: .string)
                }
                Button("編集…") { editorTarget = .edit(grant) }
                Button("トークン再生成…") { pendingRegenerate = grant }
                Button("削除…", role: .destructive) { pendingDelete = grant }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func tierBadge(_ tier: AccessTier) -> some View {
        let info: (String, String) = {
            switch tier {
            case .admin: return ("管理者", "key.fill")
            case .edit:  return ("編集可", "pencil")
            case .read:  return ("閲覧のみ", "eye")
            }
        }()
        Label(info.0, systemImage: info.1)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func scopeHelp(_ scope: GrantScope) -> String {
        switch scope {
        case .all:
            return "全ライブラリ"
        case .libraries(let ids):
            let openByUUID = GrantEditorSheet.openLibraries()
                .reduce(into: [String: String]()) { $0[$1.uuid] = $1.name }
            let names = ids.map { openByUUID[$0] ?? "(未オープン: \($0.prefix(8)))" }
            return names.joined(separator: ", ")
        }
    }
}

/// 追加/編集シートの対象。
enum GrantEditorTarget: Identifiable {
    case create
    case edit(Grant)
    var id: String {
        switch self {
        case .create: return "__create__"
        case .edit(let g): return g.id
        }
    }
}

/// グラント追加/編集シート。保存時に GrantStore を直接更新し onSaved を呼ぶ。
@MainActor
struct GrantEditorSheet: View {
    let target: GrantEditorTarget
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var tier: AccessTier = .read
    @State private var scopeIsAll: Bool = true
    @State private var selectedUUIDs: Set<String> = []
    /// 編集時、scope に含まれるが現在開いていない庫 UUID（チェック維持のため保持）。
    @State private var extraScopedUUIDs: [String] = []

    /// 現在開いているライブラリ [(uuid, name)]（名前順）。static でヘルパからも参照可能。
    @MainActor
    static func openLibraries() -> [(uuid: String, name: String)] {
        AppState.activeInstances.allObjects
            .compactMap { state -> (uuid: String, name: String)? in
                guard let uuid = state.librarySettings?.libraryUUID else { return nil }
                return (uuid, state.bundleURL.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name < $1.name }
    }

    private var isEdit: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEdit ? "グラントを編集" : "グラントを追加").font(.headline)
            Form {
                TextField("ラベル", text: $label)
                Picker("権限", selection: $tier) {
                    Text("閲覧").tag(AccessTier.read)
                    Text("編集").tag(AccessTier.edit)
                    Text("管理者").tag(AccessTier.admin)
                }
                if tier == .admin {
                    Text("⚠ 管理者トークンは設定変更・ファイル削除・グラント管理まで全操作を許可します。信頼できる自分の端末にのみ渡してください。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("見せるライブラリ", selection: $scopeIsAll) {
                    Text("全ライブラリ").tag(true)
                    Text("選んだライブラリだけ").tag(false)
                }
                .pickerStyle(.radioGroup)
                if !scopeIsAll {
                    ForEach(Self.openLibraries(), id: \.uuid) { lib in
                        Toggle(lib.name, isOn: binding(for: lib.uuid))
                    }
                    ForEach(extraScopedUUIDs, id: \.self) { uuid in
                        Toggle("(未オープン: \(uuid.prefix(8)))", isOn: binding(for: uuid))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!GrantManagementLogic.isValidInput(
                        label: label, scopeIsAll: scopeIsAll, selectedLibraryCount: selectedUUIDs.count))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: loadForEdit)
    }

    private func binding(for uuid: String) -> Binding<Bool> {
        Binding(
            get: { selectedUUIDs.contains(uuid) },
            set: { on in if on { selectedUUIDs.insert(uuid) } else { selectedUUIDs.remove(uuid) } }
        )
    }

    private func loadForEdit() {
        guard case .edit(let g) = target else { return }
        label = g.label
        tier = g.tier
        switch g.scope {
        case .all:
            scopeIsAll = true
        case .libraries(let ids):
            scopeIsAll = false
            selectedUUIDs = Set(ids)
            let openSet = Set(Self.openLibraries().map(\.uuid))
            extraScopedUUIDs = ids.filter { !openSet.contains($0) }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Set は順序非決定のため sorted() で安定化（GrantScope の等値比較・JSON シリアライズの安定性）。
        let scope: GrantScope = scopeIsAll ? .all : .libraries(Array(selectedUUIDs).sorted())
        switch target {
        case .create:
            let g = Grant(id: UUID().uuidString, label: trimmedLabel,
                          token: ServerPreferences.generateToken(),
                          tier: tier, scope: scope, createdAt: Date())
            GrantStore.add(g)
        case .edit(let existing):
            var g = existing
            g.label = trimmedLabel
            g.tier = tier
            g.scope = scope
            GrantStore.update(g)
        }
        onSaved()
        dismiss()
    }
}

/// 1 共有トークン分のペアリング QR シート。接続先 IP を選べる（自己完結）。
@MainActor
struct GrantQRSheet: View {
    let grant: Grant
    let port: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selectedHostIP: String?

    var body: some View {
        let addresses = NetworkInterfaces.addresses()
        VStack(alignment: .leading, spacing: 16) {
            Text("共有トークンの QR: \(grant.label)").font(.headline)
            if addresses.isEmpty {
                Text("ネットワークアドレスが見つかりません。Wi-Fi / 有線 / Tailscale を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if addresses.count >= 2 {
                    Picker("接続先", selection: Binding(
                        get: { selectedHostIP ?? addresses.first?.ip },
                        set: { selectedHostIP = $0 }
                    )) {
                        ForEach(addresses, id: \.ip) { addr in
                            Text("\(addr.interface) — \(addr.displayHost)").tag(Optional(addr.ip))
                        }
                    }
                }
                let chosen = addresses.first(where: { $0.ip == selectedHostIP }) ?? addresses.first
                if let chosen {
                    VStack(spacing: 8) {
                        QRCodeView(
                            content: PairingInfo.url(host: chosen.ip, port: port, token: grant.token),
                            size: 200
                        )
                        Text("接続先: \(chosen.interface) — \(chosen.displayHost)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(grant.token)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Text("iPhone のカメラで読み取ると Safari が開き自動でペアリングされます。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { selectedHostIP = ServerPreferences.preferredHostIP() }
        .onChange(of: selectedHostIP) { _, newValue in ServerPreferences.setPreferredHostIP(newValue) }
    }
}
