// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import RemoteClient
import LibraryServerAPI
import StackroomFormat  // for BookRecord（G12b-3c: プリセット プレビュー用）

/// 4.2c-8 B1(v2): リモートから開く「ライブラリ設定」シート。ツールバーの歯車から開く。
/// 実体は接続先（ローカル）ライブラリの設定をリモートで変更する UI なので呼称は「ライブラリ設定」。
///
/// G12b-2 Task 3: タブ化。G1 でローカル LibrarySettingsSheet に整列（順: 一般 / 取り込み /
/// ラベル / ロック、frame 580×640、開いたとき先頭タブを選択）。tier に応じてタブを出し分ける:
/// - ラベル: 全 tier（read でも閲覧・編集は不可＝保存ボタンで弾かれるが UI 自体は出す＝既存挙動）
/// - 取り込み: canDelete（admin）以上のみ（G12b-3a: 監視フォルダ設定も含むため admin へ再分類）
/// - ロック: canDelete（admin）以上のみ
/// - 一般: canDelete（admin）以上のみ（G12b-3a: ライブラリ名・バックアップ・整合性チェック）
/// 保存はタブごとにサーバへ PUT/POST → 成功で state / settings の override を更新する。
struct RemoteLibrarySettingsSheet: View {
    let state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    @Environment(\.dismiss) private var dismiss

    /// 現在表示中の設定タブ (0=ラベル / 1=取り込み / 2=ロック / 3=一般)。
    @State private var settingsTab = 0
    @State private var errorText: String?
    @State private var saving = false

    // MARK: ラベルタブ

    @State private var stagedFieldLabels: [String: String] = [:]
    @State private var stagedBookTypeLabels: [String: String] = [:]

    // MARK: 取り込みタブ（canDelete 以上）

    @State private var importAutoClassify: Bool?
    @State private var thickThreshold: Int?
    @State private var thickThresholdInput: String = ""
    @State private var importConfigLoaded = false

    // MARK: ロックタブ（canDelete 以上）

    @State private var lockToggleOn = false
    @State private var passwordInput = ""
    @State private var passwordConfirm = ""
    @State private var confirmingDisableLock = false

    // MARK: 自動追加（監視フォルダ）— smoke b: 取り込みタブ内。importConfigLoaded でまとめてロード。
    @State private var watchConfig: WatchConfigDTO?
    @State private var newFolderPath = ""
    // S4: 追加時に「既存も取り込む」（ローカル parity・既定 ON）。ON で追加したフォルダのパスを保存後の
    // importExisting 対象として記録する（保存＝watch-config PUT は新規フォルダを baseline=既存で作るため、
    // 保存後に該当フォルダの baseline をクリアして既存も取り込む）。
    @State private var importExistingOnAdd = true
    @State private var pendingImportPaths: Set<String> = []
    @State private var scanningNow = false
    // G12b-3c: per-folder「既存も取り込む」確認ダイアログ対象（folder.id を保持。行の index ではなく
    // id で追跡し、確認表示中に他行の削除で index がずれても誤爆しないようにする）。
    @State private var confirmingImportExistingFolderID: String?

    // MARK: 命名プリセット（G12b-3c: 独立「フォーマット」タブ・canDelete 以上・ローカル formatSection と parity）
    // ステージング編集は保存でのみサーバへ反映する（ローカル LibrarySettingsSheet と同方針）。
    // 保存は import/watch とは独立した専用ボタン（saveImportAndWatch のフローに含めない）。
    @State private var stagedPresets: [FilenameFormatPresetDTO] = []
    @State private var stagedDefaultID: String = ""
    @State private var selectedPresetID: String = ""
    @State private var presetName: String = ""
    @State private var formatString: String = ""
    @State private var formatError: String? = nil
    @State private var samplePreview: [String] = []
    @State private var presetsLoaded = false
    @State private var presetSaving = false
    @State private var presetSaveMessage: String? = nil

    // MARK: 一般タブ（canDelete 以上）— G12b-3a: ライブラリ名・バックアップ・整合性チェック・scan-now。

    @State private var general: GeneralSettingsDTO?
    @State private var generalLoaded = false
    @State private var integrityResult: IntegrityCheckDTO?
    @State private var showIntegrity = false

    var body: some View {
        VStack(spacing: 0) {
            Text("ライブラリ設定")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)

            TabView(selection: $settingsTab) {
                // ローカル LibrarySettingsSheet のタブ順（一般/フォーマット/取り込み/ラベル/ロック）に
                // 合わせる。S3: 命名プリセットを「フォーマット」独立タブ（一般と取り込みの間・tag 4）へ。
                // tag は据え置き（saveCurrentTab / 保存ボタン無効判定が tag 番号を参照するため）。
                if state.canDelete {
                    ScrollView { generalTab().padding(16) }
                        .tabItem { Label("一般", systemImage: "gearshape") }
                        .tag(3)
                }

                // S3: フォーマット（命名プリセット）＝ローカル formatSection の独立タブ parity。
                if state.canDelete {
                    ScrollView { formatTab().padding(16) }
                        .tabItem { Label("フォーマット", systemImage: "textformat") }
                        .tag(4)
                }

                if state.canDelete {
                    ScrollView { importTab().padding(16) }
                        .tabItem { Label("取り込み", systemImage: "tray.and.arrow.down") }
                        .tag(1)
                }

                ScrollView { labelTab().padding(16) }
                    .tabItem { Label("ラベル", systemImage: "tag") }
                    .tag(0)

                if state.canDelete {
                    ScrollView { lockTab().padding(16) }
                        .tabItem { Label("ロック", systemImage: "lock") }
                        .tag(2)
                }
            }
            .padding(.horizontal, 12)

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }

            Divider()
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task { await saveCurrentTab() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (settingsTab == 2 && lockToggleOn && !state.locked
                        && (passwordInput.isEmpty || passwordInput != passwordConfirm))
                        || (settingsTab == 4 && formatError != nil))   // S3: フォーマットタブは不正フォーマット時 保存不可
            }
            .padding(16)
        }
        .frame(width: 580, height: 640)
        .onAppear {
            stagedFieldLabels = settings.remoteFieldLabelOverride ?? [:]
            stagedBookTypeLabels = settings.remoteBookTypeLabelOverride ?? [:]
            lockToggleOn = state.locked
            // G1: ローカル同様、開いたとき先頭タブを選択（admin=一般 tag3 / 非 admin=ラベル tag0）。
            settingsTab = state.canDelete ? 3 : 0
        }
    }

    // MARK: - ラベルタブ

    @ViewBuilder
    private func labelTab() -> some View {
        LabelEditorView(
            fieldLabels: $stagedFieldLabels,
            bookTypeLabels: $stagedBookTypeLabels,
            fieldRows: LibrarySettingsSheet.fieldLabelRows,
            bookTypeRows: LibrarySettingsSheet.bookTypeLabelRows)
    }

    private func saveLabels() async {
        saving = true
        defer { saving = false }
        do {
            let saved = try await state.saveLabels(
                customFieldLabels: stagedFieldLabels, customBookTypeLabels: stagedBookTypeLabels)
            settings.remoteFieldLabelOverride = saved.customFieldLabels
            settings.remoteBookTypeLabelOverride = saved.customBookTypeLabels
            errorText = nil
            dismiss()
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else { errorText = "ラベルの更新に失敗しました" }
        }
    }

    // MARK: - 取り込みタブ（canDelete 以上）

    @ViewBuilder
    private func importTab() -> some View {
        // smoke b: ローカル同様「取り込み」タブに 自動分類（importSection 相当）＋自動追加（watchSection 相当）を並べる。
        VStack(alignment: .leading, spacing: 16) {
        GroupBox("自動分類") {
            VStack(alignment: .leading, spacing: 12) {
                Text("「既定に従う」を選ぶと、サーバのグローバル設定を使います。")
                    .font(.caption).foregroundStyle(.secondary)

                // 本の種類を自動分類（3-way: 既定に従う / 有効 / 無効）
                VStack(alignment: .leading, spacing: 6) {
                    Text("本の種類を自動分類")
                    Picker("", selection: Binding(
                        get: {
                            switch importAutoClassify {
                            case nil: return 0
                            case .some(true): return 1
                            case .some(false): return 2
                            }
                        },
                        set: { (sel: Int) in
                            importAutoClassify = (sel == 0) ? nil : (sel == 1)
                        }
                    )) {
                        Text("既定に従う").tag(0)
                        Text("このライブラリで有効").tag(1)
                        Text("このライブラリで無効").tag(2)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Divider()

                // 厚い本の閾値（既定に従う / 上書き）
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("厚い本の閾値を既定に従う", isOn: Binding(
                        get: { thickThreshold == nil },
                        set: { inherit in
                            if inherit {
                                thickThreshold = nil
                            } else {
                                let v = thickThreshold ?? 20
                                thickThreshold = v
                                thickThresholdInput = String(v)
                            }
                        }
                    ))
                    if thickThreshold != nil {
                        HStack {
                            Text("厚い本判定閾値（ページ数）")
                            Spacer()
                            TextField("", text: $thickThresholdInput)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .lineLimit(1)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .onChange(of: thickThresholdInput) { _, newValue in
                                    let cleaned = String(newValue.filter(\.isNumber).prefix(3))
                                    if cleaned != newValue { thickThresholdInput = cleaned }
                                }
                                .onSubmit { commitThickThresholdInput() }
                            Stepper("", value: Binding(
                                get: { thickThreshold ?? 20 },
                                set: { newValue in
                                    let clamped = max(5, min(100, newValue))
                                    thickThreshold = clamped
                                    thickThresholdInput = String(clamped)
                                }
                            ), in: 5...100, step: 1)
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(8)
        }

        watchSection()
        }
        .task {
            guard !importConfigLoaded else { return }
            importConfigLoaded = true
            if let dto = await state.loadImportConfig() {
                importAutoClassify = dto.autoClassifyEnabled
                thickThreshold = dto.thickBookThreshold
                if let t = dto.thickBookThreshold { thickThresholdInput = String(t) }
            }
            // smoke b: 自動追加も同じ「取り込み」タブでロードする。
            watchConfig = await state.loadWatchConfig()
            if watchConfig == nil { errorText = state.errorText }
        }
    }

    // MARK: - フォーマット（命名プリセット）タブ — S3: ローカル formatSection の独立タブ parity。
    @ViewBuilder
    private func formatTab() -> some View {
        presetSection()
            .task {
                guard state.canDelete, !presetsLoaded else { return }
                presetsLoaded = true
                await reloadPresetsFromServer()
            }
    }

    /// サーバから命名プリセット集合を取得し、ステージへ反映する（初回ロード／保存成功後の再同期で共用）。
    private func reloadPresetsFromServer() async {
        guard let dto = await state.loadPresets() else { return }
        stagedPresets = dto.presets
        stagedDefaultID = dto.defaultID
        selectedPresetID = stagedDefaultID.isEmpty ? (stagedPresets.first?.id ?? "") : stagedDefaultID
        loadSelectedStagedPreset()
    }

    /// 取り込みタブの閾値 TextField をコミット（ローカル LibrarySettingsSheet の同名処理相当）。
    private func commitThickThresholdInput() {
        if let v = Int(thickThresholdInput) {
            thickThreshold = max(5, min(100, v))
        }
        thickThresholdInput = String(thickThreshold ?? 20)
    }

    // MARK: - ロックタブ（canDelete 以上）

    @ViewBuilder
    private func lockTab() -> some View {
        GroupBox("ロック設定") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("このライブラリにパスワードロックを設定する", isOn: Binding(
                    get: { state.locked || lockToggleOn },
                    set: { newVal in
                        if state.locked && !newVal {
                            // ON → OFF 切替: confirm dialog を表示、即クリアしない
                            confirmingDisableLock = true
                        } else if !state.locked && newVal {
                            // OFF → ON 切替: 新規 password 入力フィールド表示
                            lockToggleOn = true
                        } else {
                            lockToggleOn = newVal
                        }
                    }
                ))

                if lockToggleOn && !state.locked {
                    SecureField("パスワード", text: $passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    SecureField("パスワード (確認)", text: $passwordConfirm)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)

                    if !passwordInput.isEmpty && passwordInput != passwordConfirm {
                        Text("確認パスワードが一致しません")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("「保存」でこのライブラリにロックを設定します。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if state.locked {
                    Text("現在ロック中です。解除するにはトグルを OFF にしてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .confirmationDialog(
            "ロックを解除しますか？",
            isPresented: $confirmingDisableLock,
            titleVisibility: .visible
        ) {
            Button("解除する", role: .destructive) {
                Task { await disableLock() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このライブラリのパスワードロックを解除します。")
        }
    }

    private func saveLock() async {
        // 既にロック中で toggle が変化していない場合は何もしない（保存対象なし）。
        guard lockToggleOn, !state.locked else { return }
        guard !passwordInput.isEmpty, passwordInput == passwordConfirm else {
            errorText = "パスワードが一致しません"
            return
        }
        saving = true
        defer { saving = false }
        state.errorText = nil
        await state.setLibraryLock(password: passwordInput)
        if state.errorText == nil {
            // IMP-1 (G12b-2 whole-branch review): 現在のリモートセッションは continued 前提。
            // state.locked を立てると RemoteLibraryView の isUnlockFormShown が真になり、
            // 設定した瞬間に自分自身が解錠フォームへ落とされてしまう。
            // ロックはサーバ側に保存済みなので、次回接続時から効く（現セッションは継続）。
            passwordInput = ""
            passwordConfirm = ""
            errorText = nil
            dismiss()
        } else {
            errorText = state.errorText
        }
    }

    private func disableLock() async {
        saving = true
        defer { saving = false }
        state.errorText = nil
        await state.clearLibraryLock()
        if state.errorText == nil {
            state.locked = false
            lockToggleOn = false
            errorText = nil
            dismiss()
        } else {
            errorText = state.errorText
        }
    }

    // MARK: - 一般タブ（canDelete 以上）— G12b-3a

    @ViewBuilder
    private func generalTab() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("一般") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("ライブラリ名").frame(width: 120, alignment: .leading)
                        TextField("", text: Binding(
                            get: { general?.displayName ?? "" },
                            set: { general?.displayName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(general == nil)
                    }
                    Text("ブラウザのタイトルやリモート配信名に使われます。空欄でバンドル名にフォールバックします。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }

            // G12b-3b smoke: ローカル一般タブに合わせ 一般 / メタデータ / バックアップ の順にする
            // （ローカル LibrarySettingsSheet の generalSection→metadataSection→backupSection と整合）。
            GroupBox("メタデータ") {
                VStack(alignment: .leading, spacing: 10) {
                    if let job = state.maintenanceJob {
                        let label = job.job == "compress-covers" ? "表紙を圧縮中…" : "メタデータを補完中…"
                        HStack {
                            if job.total > 0 { ProgressView(value: Double(job.done), total: Double(job.total)) }
                            else { ProgressView() }
                            Text(job.total > 0 ? "\(job.done)/\(job.total)" : "").font(.caption).monospacedDigit()
                            Button("中断") { Task { await state.cancelMaintenance() } }
                        }
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("ファイル名からシリーズ・巻数を補完") { Task { await state.runCompleteMetadata() } }
                            .disabled(!state.canDelete)
                        Text("既存のシリーズ・巻数が空欄の本のみ、タイトル／ファイル名から自動推測して補完します。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Button { Task { await state.runCompressCovers() } } label: {
                            Label("表紙を圧縮", systemImage: "arrow.down.circle")
                        }
                        .disabled(!state.canDelete)
                        Text("上限 1200px を超える内部表紙のみ圧縮します（外部表紙は対象外）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("バックアップ") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("編集後にバックアップを保存", isOn: Binding(
                        get: { general?.backupEnabled ?? false },
                        set: { general?.backupEnabled = $0 }
                    ))
                    .disabled(general == nil)

                    Stepper(value: Binding(
                        get: { general?.backupGenerations ?? 1 },
                        set: { general?.backupGenerations = $0 }
                    ), in: 1...20) {
                        Text("保持する世代数: \(general?.backupGenerations ?? 1)")
                    }
                    .disabled(general == nil || !(general?.backupEnabled ?? false))

                    Divider()

                    HStack {
                        Button("今すぐバックアップ") {
                            Task {
                                if await state.runBackupNow() == false { errorText = state.errorText }
                            }
                        }
                        .disabled(general == nil)
                        Button("整合性をチェック") {
                            Task {
                                integrityResult = await state.runIntegrityCheck()
                                if integrityResult == nil { errorText = state.errorText }
                                showIntegrity = integrityResult != nil
                            }
                        }
                        .disabled(general == nil)
                    }

                    Text("有効にすると、サーバ側でホスト側の設定に従いバックアップ・世代管理を行います。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }

            if general == nil {
                if errorText != nil {
                    Button("再読み込み") {
                        Task {
                            errorText = nil
                            general = await state.loadGeneralSettings()
                            if general == nil { errorText = state.errorText }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task {
            guard !generalLoaded else { return }
            generalLoaded = true
            general = await state.loadGeneralSettings()
            if general == nil { errorText = state.errorText }
        }
        .alert("整合性チェック", isPresented: $showIntegrity) {
            Button("OK") {}
        } message: {
            if let integrityResult {
                Text(integrityResult.healthy
                    ? "問題は見つかりませんでした"
                    : integrityResult.rows.prefix(20).joined(separator: "\n"))
            }
        }
        .alert("メンテナンス完了", isPresented: Binding(
            get: { state.maintenanceResult != nil },
            set: { if !$0 { state.maintenanceResult = nil } }
        )) {
            Button("OK") { state.maintenanceResult = nil }
        } message: {
            Text(state.maintenanceResult ?? "")
        }
    }

    private func saveGeneral() async {
        guard let g = general else { return }
        saving = true
        defer { saving = false }
        state.errorText = nil
        errorText = nil
        if let saved = await state.saveGeneralSettings(g) {
            general = saved
            errorText = nil
            dismiss()
        } else {
            errorText = state.errorText
        }
    }

    // MARK: - 保存ディスパッチ

    private func saveCurrentTab() async {
        switch settingsTab {
        case 0: await saveLabels()
        case 1: await saveImportAndWatch()   // smoke b: 取り込みタブは 自動分類＋自動追加 を両方保存
        case 2: await saveLock()
        case 3: await saveGeneral()
        case 4: await savePresetsNow()       // S3: フォーマットタブ（命名プリセット）
        default: break
        }
    }

    // MARK: - 自動追加（監視フォルダ）セクション — smoke b: ローカル同様「取り込み」タブ内に置く

    @ViewBuilder
    private func watchSection() -> some View {
        // smoke c: 「自動追加を有効にする」OFF のときは関連項目を全てグレーアウトする。
        let watchEnabled = watchConfig?.enabled ?? false
        GroupBox("自動追加") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("自動追加を有効にする", isOn: Binding(
                    get: { watchConfig?.enabled ?? false },
                    set: { watchConfig?.enabled = $0 }
                ))
                .disabled(watchConfig == nil)   // 未ロード時はトグルも触らせない
                Text("監視フォルダに入った本を自動でライブラリに追加します（ホスト側で実行）。")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task {
                            scanningNow = true
                            defer { scanningNow = false }
                            _ = await state.runScanNow()
                        }
                    } label: {
                        if scanningNow { ProgressView().controlSize(.small) }
                        Text("今すぐスキャン")
                    }
                    .disabled(scanningNow)
                    Text("自動追加の有効/無効に関わらず、監視フォルダを即座にスキャンします。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                if watchConfig != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        if let cfg = watchConfig {
                            if cfg.folders.isEmpty {
                                Text("監視フォルダが未設定です。下の入力で追加してください。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(cfg.folders.indices, id: \.self) { i in
                                watchFolderRow(i)
                                Divider()
                            }
                        }
                        HStack {
                            TextField("追加する監視フォルダのホスト絶対パス（例: /Users/you/Watch）", text: $newFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("フォルダを追加") { addWatchFolderRow() }
                                .disabled(newFolderPath.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Toggle("既存ファイルも取り込む（ローカル同様。OFF で以降の新規のみ）", isOn: $importExistingOnAdd)
                            .font(.caption)
                        Text("パスはホスト（サーバ機）の絶対パスです。保存時に存在を検証します。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .disabled(!watchEnabled)   // smoke c: 自動追加 OFF なら中身をグレーアウト
                } else if errorText != nil {
                    Button("再読み込み") {
                        Task {
                            errorText = nil
                            watchConfig = await state.loadWatchConfig()
                            if watchConfig == nil { errorText = state.errorText }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func watchFolderRow(_ i: Int) -> some View {
        if let cfg = watchConfig, cfg.folders.indices.contains(i) {
            // Codex review: 行 binding の get/set を bounds-safe にする。削除（特に末尾）と Toggle/Picker の
            // in-flight 更新が競合しても、範囲外 index を掴んで trap したり別行へ誤適用しないようにする。
            let inBounds = { self.watchConfig?.folders.indices.contains(i) == true }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { inBounds() ? (watchConfig?.folders[i].enabled ?? false) : false },
                        set: { if inBounds() { watchConfig?.folders[i].enabled = $0 } }
                    )).labelsHidden()
                    Text(cfg.folders[i].path).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        if inBounds() { watchConfig?.folders.remove(at: i) }
                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                HStack {
                    Text("フォーマット").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { inBounds() ? (watchConfig?.folders[i].presetID ?? "") : "" },
                        set: { if inBounds() { watchConfig?.folders[i].presetID = $0.isEmpty ? nil : $0 } }
                    )) {
                        Text("ライブラリ既定").tag("")
                        ForEach(cfg.presets ?? [], id: \.id) { p in Text(p.name).tag(p.id) }
                    }.labelsHidden().frame(maxWidth: 240)
                }
                HStack {
                    Text("サブフォルダ").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { inBounds() ? (watchConfig?.folders[i].subfolderMode ?? .topLevelOnly) : .topLevelOnly },
                        set: { if inBounds() { watchConfig?.folders[i].subfolderMode = $0 } }
                    )) {
                        Text("サブフォルダを取り込まない").tag(WatchedFolderDTO.SubfolderMode.topLevelOnly)
                        Text("サブフォルダの中も取り込む").tag(WatchedFolderDTO.SubfolderMode.recurse)
                    }.labelsHidden().frame(maxWidth: 260)
                }
                HStack {
                    Button("既存も取り込む") {
                        if inBounds() { confirmingImportExistingFolderID = cfg.folders[i].id }
                    }
                    .disabled(!state.canDelete)
                    Text("このフォルダに元からあるファイルもまとめて取り込みます。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .confirmationDialog(
                    "このフォルダ内の既存ファイルも取り込みます。よろしいですか？",
                    isPresented: Binding(
                        get: { confirmingImportExistingFolderID == cfg.folders[i].id },
                        set: { if !$0 { confirmingImportExistingFolderID = nil } }
                    )
                ) {
                    Button("取り込む", role: .destructive) {
                        if let fid = confirmingImportExistingFolderID {
                            confirmingImportExistingFolderID = nil
                            Task { await state.importExisting(folderID: fid) }
                        }
                    }
                    Button("キャンセル", role: .cancel) { confirmingImportExistingFolderID = nil }
                }
            }
        }
    }

    private func addWatchFolderRow() {
        let path = newFolderPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        let folder = WatchedFolderDTO(id: UUID().uuidString, path: path, enabled: true)
        guard watchConfig != nil else { return }   // ロード失敗時は config を捏造しない（既存監視フォルダの全消しを防ぐ）
        watchConfig?.folders.append(folder)
        // S4: 「既存も取り込む」ON なら保存後の importExisting 対象として path を記録。
        if importExistingOnAdd { pendingImportPaths.insert(path) }
        newFolderPath = ""
    }

    // MARK: - 命名プリセット セクション（G12b-3c: 取り込みタブ内・ローカル formatSection と parity）

    @ViewBuilder
    private func presetSection() -> some View {
        GroupBox("命名プリセット") {
            VStack(alignment: .leading, spacing: 8) {
                if stagedPresets.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("読み込み中…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Picker("プリセット", selection: $selectedPresetID) {
                            ForEach(stagedPresets, id: \.id) { p in
                                Text(p.id == stagedDefaultID ? "★ \(presetDisplayName(p))" : presetDisplayName(p))
                                    .tag(p.id)
                            }
                        }
                        .frame(maxWidth: 240)
                        .onChange(of: selectedPresetID) { _, _ in loadSelectedStagedPreset() }
                        Spacer()
                        Button("追加") { addStagedPreset() }
                        Button("複製") { duplicateStagedPreset() }
                        Button("削除") { deleteStagedPreset() }
                            .disabled(stagedPresets.count <= 1)
                    }

                    HStack {
                        Text("名前").frame(width: 40, alignment: .leading)
                        TextField("プリセット名", text: $presetName)
                            .onChange(of: presetName) { _, new in
                                updateSelectedStagedPreset(name: new, format: formatString)
                            }
                        Button(selectedPresetID == stagedDefaultID ? "既定 ✓" : "既定に設定") {
                            stagedDefaultID = selectedPresetID
                        }
                        .disabled(selectedPresetID == stagedDefaultID)
                    }

                    TextField("フォーマット（例: @title [@keywordA]）", text: $formatString)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: formatString) { _, new in
                            updatePresetPreview(new)
                            updateSelectedStagedPreset(name: presetName, format: new)
                        }

                    HStack {
                        Menu("トークンを挿入") {
                            ForEach(FormatToken.allCases, id: \.self) { tok in
                                Button(tok.rawSyntax) { insertPresetToken(tok.rawSyntax) }
                            }
                        }
                        .frame(maxWidth: 160)
                        Spacer()
                    }

                    if let err = formatError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }

                    Text("プレビュー:").font(.caption.bold()).padding(.top, 4)
                    ForEach(Array(samplePreview.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("⚠ コロン (:) は ： に自動変換されます")
                        .font(.caption2).foregroundStyle(.secondary)
                    // S3: 専用保存ボタンは廃止。独立「フォーマット」タブになったため、他タブと同様に
                    // シート下部の「保存」ボタン（saveCurrentTab→case 4→savePresetsNow）で保存する。
                }
            }
            .padding(8)
        }
    }

    /// プリセット 1 件の Picker/一覧表示名（name 空白のみなら format で代替。ローカル displayName 相当）。
    private func presetDisplayName(_ p: FilenameFormatPresetDTO) -> String {
        let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (p.format ?? "") : p.name
    }

    private func loadSelectedStagedPreset() {
        guard let p = stagedPresets.first(where: { $0.id == selectedPresetID }) else { return }
        presetName = p.name
        formatString = p.format ?? ""
        updatePresetPreview(formatString)
    }

    private func updateSelectedStagedPreset(name: String, format: String) {
        guard let i = stagedPresets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        stagedPresets[i].name = name
        stagedPresets[i].format = format
    }

    private func addStagedPreset() {
        let p = FilenameFormatPresetDTO(id: UUID().uuidString, name: "新規プリセット", format: "@title")
        stagedPresets.append(p)
        selectedPresetID = p.id
        loadSelectedStagedPreset()
    }

    private func duplicateStagedPreset() {
        guard let src = stagedPresets.first(where: { $0.id == selectedPresetID }) else { return }
        let p = FilenameFormatPresetDTO(id: UUID().uuidString, name: src.name + " のコピー", format: src.format ?? "")
        stagedPresets.append(p)
        selectedPresetID = p.id
        loadSelectedStagedPreset()
    }

    private func deleteStagedPreset() {
        // FilenameFormatPresetLogic（AppCore・ローカルと共通）は非 optional format の
        // FilenameFormatPreset を扱うため、往復変換してから流用する（最低 1 個ガードを含む）。
        let converted = stagedPresets.map { FilenameFormatPreset(id: $0.id, name: $0.name, format: $0.format ?? "") }
        let r = FilenameFormatPresetLogic.removing(id: selectedPresetID, presets: converted, defaultID: stagedDefaultID)
        stagedPresets = r.presets.map { FilenameFormatPresetDTO(id: $0.id, name: $0.name, format: $0.format) }
        stagedDefaultID = r.defaultID
        selectedPresetID = stagedPresets.first?.id ?? ""
        loadSelectedStagedPreset()
    }

    /// 現在フォーカス位置の概念を持たないプレーン TextField 版のトークン挿入（末尾に追記）。
    private func insertPresetToken(_ token: String) {
        formatString += token
    }

    private func updatePresetPreview(_ raw: String) {
        do {
            let format = try FilenameFormat(raw: raw)
            samplePreview = Self.presetSampleRecords.map { record in
                "  • " + FilenameFormatter.format(record, with: format, bookTypeLabels: settings.bookTypeLabelOverrides)
            }
            formatError = nil
        } catch let error as FilenameFormat.ParseError {
            formatError = presetDescribe(error)
            samplePreview = []
        } catch {
            formatError = "構文エラー"
            samplePreview = []
        }
    }

    private func presetDescribe(_ e: FilenameFormat.ParseError) -> String {
        switch e {
        case .unknownToken(let raw): return "未知のトークン: \(raw)"
        case .unclosedBracket(let c): return "閉じていない括弧: \(c)"
        case .nestedBracket: return "括弧のネストはサポートされません"
        }
    }

    /// 3 件のダミーレコードでプレビュー（ローカル LibrarySettingsSheet.sampleRecords と同一内容）。
    private static let presetSampleRecords: [BookRecord] = [
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第01巻",
            author: "佐藤秀峰",
            genre: "一般コミック",
            dateAdded: Date(),
            keywordA: "医療",
            keywordB: "名作"
        ),
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第02巻",
            author: "佐藤秀峰",
            genre: "一般コミック",
            dateAdded: Date(),
            keywordA: "医療"
        ),
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第03巻",
            dateAdded: Date()
        )
    ]

    /// 専用「プリセットを保存」ボタン: import/watch の保存フローとは独立して即座に PUT する。
    /// 成功で適用後 DTO をステージへ反映（サーバの正規化・既定 id 検証を反映するため）。
    private func savePresetsNow() async {
        presetSaving = true
        presetSaveMessage = nil
        defer { presetSaving = false }
        let dto = PresetSetDTO(presets: stagedPresets, defaultID: stagedDefaultID)
        if let saved = await state.savePresets(dto) {
            stagedPresets = saved.presets
            stagedDefaultID = saved.defaultID
            selectedPresetID = stagedDefaultID.isEmpty ? (stagedPresets.first?.id ?? "") : stagedDefaultID
            loadSelectedStagedPreset()
            presetSaveMessage = "保存しました"
        } else {
            presetSaveMessage = state.errorText
        }
    }

    /// smoke b: 「取り込み」タブの保存 = 監視設定 → 取り込み設定 の順に PUT。
    /// Codex review: 検証で失敗し得る監視設定（不正パス 400）を先に PUT し、失敗時は取り込み設定を
    /// commit しない（非アトミックな部分保存＝ユーザーがキャンセルしても取り込みだけ変わる、を避ける）。
    private func saveImportAndWatch() async {
        saving = true
        defer { saving = false }
        state.errorText = nil
        errorText = nil
        // 1) 監視設定（ロード済みのときのみ。未ロード=nil のときは触らない＝既存監視フォルダの全消しを防ぐ）
        if let cfg = watchConfig {
            if let applied = await state.saveWatchConfig(cfg) {
                watchConfig = applied   // 適用後（新規 baseline 等）で置換
                // S4: 「既存も取り込む」ON で追加したフォルダは、サーバが baseline=既存で作るため、
                // 保存後に該当フォルダ（path 一致）の baseline をクリアして既存も取り込む（既存 endpoint 再利用）。
                if !pendingImportPaths.isEmpty {
                    for f in applied.folders where pendingImportPaths.contains(f.path) {
                        await state.importExisting(folderID: f.id)
                    }
                    pendingImportPaths.removeAll()
                }
            } else {
                // 400 の不正パス文言など。取り込み設定は保存しない。シートは閉じない。
                errorText = state.errorText
                return
            }
        }
        // 2) 取り込み設定（監視が通ってから）
        state.errorText = nil
        let importDTO = ImportConfigDTO(autoClassifyEnabled: importAutoClassify, thickBookThreshold: thickThreshold)
        await state.saveImportConfig(importDTO)
        if state.errorText != nil { errorText = state.errorText; return }
        dismiss()
    }
}
