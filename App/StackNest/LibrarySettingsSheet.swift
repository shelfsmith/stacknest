// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit  // for NSAlert / NSWorkspace (backup section)
import AppCore
import LibraryStore
import StackroomFormat  // for BookRecord
import OSLog

private let settingsLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibrarySettingsSheet")

struct LibrarySettingsSheet: View {
    @Bindable var settings: LibrarySettings
    let bundleName: String
    let bundleURL: URL?
    var appState: AppState? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State private var formatString: String = ""
    @State private var formatError: String? = nil
    @State private var samplePreview: [String] = []
    @State private var cursorRange = NSRange(location: 0, length: 0)

    // B6: プリセット編集はステージし、保存でのみ settings に反映する。
    @State private var stagedPresets: [FilenameFormatPreset] = []
    @State private var stagedDefaultID: String = ""
    @State private var selectedPresetID: String = ""
    @State private var presetName: String = ""

    // Lock section state
    @State var lockToggleOn = false
    @State var passwordInput = ""
    @State var passwordConfirm = ""
    @State var useBiometricInput = false
    @State var confirmingDisableLock = false
    @State var disableLockPassword = ""
    @State var disableLockError: String? = nil

    // Recompute metadata section state
    @State private var showRecomputeResult = false
    @State private var recomputeResultMessage = ""

    // Phase 2.5h B19: 表紙圧縮 (CoverRegenerationTask) UI 状態
    @State private var showRegenerationConfirm = false
    @State private var regenerationTask: CoverRegenerationTask?
    @State private var regenerationProgress: (Int, Int) = (0, 0)
    @State private var showRegenerationResult = false
    @State private var regenerationSavedMB: Double = 0

    // Phase 2.7 ラベルカスタマイズ: 編集は一時状態にステージし、「保存」でのみ settings に反映する
    // （ファイル名フォーマット・ロック設定と同じく「キャンセル」で破棄＝シートの挙動を統一）。
    @State var stagedFieldLabels: [String: String] = [:]
    @State var stagedBookTypeLabels: [String: String] = [:]

    /// 現在表示中の設定タブ (0=一般 / 1=フォーマット / 2=ラベル / 3=ロック / 4=監視フォルダ / 5=取り込み)。
    @State private var settingsTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("「\(bundleName)」 の設定")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)

            TabView(selection: $settingsTab) {
                ScrollView { generalSection().padding(16) }
                    .tabItem { Label("一般", systemImage: "gearshape") }
                    .tag(0)
                ScrollView { formatSection().padding(16) }
                    .tabItem { Label("フォーマット", systemImage: "textformat") }
                    .tag(1)
                ScrollView { labelSection().padding(16) }
                    .tabItem { Label("ラベル", systemImage: "tag") }
                    .tag(2)
                ScrollView { lockSection().padding(16) }
                    .tabItem { Label("ロック", systemImage: "lock") }
                    .tag(3)
                ScrollView { watchSection().padding(16) }
                    .tabItem { Label("監視フォルダ", systemImage: "folder.badge.gearshape") }
                    .tag(4)
                ScrollView { importSection().padding(16) }
                    .tabItem { Label("取り込み", systemImage: "tray.and.arrow.down") }
                    .tag(5)
            }
            .padding(.horizontal, 12)

            Divider()
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        formatError != nil ||
                        formatString.isEmpty ||
                        (lockToggleOn && !passwordInput.isEmpty && passwordInput != passwordConfirm)
                    )
            }
            .padding(16)
        }
        .frame(width: 580, height: 640)
        .onAppear {
            stagedPresets = settings.filenameFormatPresets
            stagedDefaultID = settings.defaultFilenameFormatPresetID
            selectedPresetID = stagedDefaultID.isEmpty ? (stagedPresets.first?.id ?? "") : stagedDefaultID
            loadSelectedPreset()
            lockToggleOn = settings.lockPasswordHash != nil
            useBiometricInput = settings.useBiometric
            stagedFieldLabels = settings.customFieldLabels
            stagedBookTypeLabels = settings.customBookTypeLabels
        }
        .confirmationDialog(
            "表紙を圧縮します",
            isPresented: $showRegenerationConfirm,
            titleVisibility: .visible
        ) {
            Button("圧縮 (\(bookCount) 件)") {
                startRegeneration()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("上限 1200 px を超える表紙を圧縮します。続行しますか?")
        }
        .sheet(isPresented: Binding(
            get: { regenerationTask != nil && !showRegenerationResult },
            set: { _ in }
        )) {
            VStack(spacing: 16) {
                Text("表紙を圧縮中…").font(.headline)
                ProgressView(value: Double(regenerationProgress.0),
                             total: Double(max(regenerationProgress.1, 1)))
                Text("\(regenerationProgress.0) / \(regenerationProgress.1)")
                    .monospacedDigit()
                Button("中断") {
                    regenerationTask?.cancel()
                }
            }
            .padding(24)
            .frame(width: 320)
        }
        .alert("圧縮完了", isPresented: $showRegenerationResult) {
            Button("OK") { regenerationTask = nil }
        } message: {
            Text(String(format: "%d 件処理、約 %.1f MB 削減",
                        regenerationProgress.0, regenerationSavedMB))
        }
    }

    // MARK: - Phase 2.5h B19: 表紙圧縮 (メタデータ節に統合)

    private var bookCount: Int {
        guard let db = appState?.database else { return 0 }
        return (try? db.fetchAllBooks().count) ?? 0
    }

    private func startRegeneration() {
        guard let db = appState?.database, let url = bundleURL else { return }
        let task = CoverRegenerationTask(database: db, bundleURL: url)
        regenerationTask = task
        regenerationProgress = (0, task.totalCount)
        Task { @MainActor in
            await task.run { processed, total in
                regenerationProgress = (processed, total)
            }
            regenerationSavedMB = Double(task.bytesSavedEstimate) / (1024 * 1024)
            showRegenerationResult = true
        }
    }

    // MARK: - B6: ファイル名フォーマット（プリセット）セクション

    @ViewBuilder
    private func formatSection() -> some View {
        GroupBox("ファイル名フォーマット（プリセット）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("プリセット", selection: $selectedPresetID) {
                        ForEach(stagedPresets) { p in
                            Text(p.id == stagedDefaultID ? "★ \(p.displayName)" : p.displayName).tag(p.id)
                        }
                    }
                    .frame(maxWidth: 240)
                    .onChange(of: selectedPresetID) { _, _ in loadSelectedPreset() }
                    Spacer()
                    Button("追加") { addPreset() }
                    Button("複製") { duplicatePreset() }
                    Button("削除") { deletePreset() }
                        .disabled(stagedPresets.count <= 1)
                }

                HStack {
                    Text("名前").frame(width: 40, alignment: .leading)
                    TextField("プリセット名", text: $presetName)
                        .onChange(of: presetName) { _, new in updateSelectedPreset(name: new, format: formatString) }
                    Button(selectedPresetID == stagedDefaultID ? "既定 ✓" : "既定に設定") {
                        stagedDefaultID = selectedPresetID
                    }
                    .disabled(selectedPresetID == stagedDefaultID)
                }

                CursorTrackingTextField(text: $formatString, selectedRange: $cursorRange)
                    .frame(height: 28)
                    .onChange(of: formatString) { _, new in
                        updatePreview(new)
                        updateSelectedPreset(name: presetName, format: new)
                    }

                HStack {
                    Menu("トークンを挿入") {
                        ForEach(FormatToken.allCases, id: \.self) { tok in
                            Button(tok.rawSyntax) { insertToken(tok.rawSyntax) }
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
            }
            .padding(8)
        }
    }

    // MARK: - Phase 4.2c-3: 一般セクション（ライブラリ名 + メタデータ + バックアップ）

    @ViewBuilder
    private func generalSection() -> some View {
        GroupBox("一般") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ライブラリ名").frame(width: 120, alignment: .leading)
                    TextField("未指定の場合「\(bundleName)」", text: $settings.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                Text("ブラウザのタイトルやリモート配信名に使われます。空欄でファイル名「\(bundleName)」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        metadataSection()
        backupSection()
    }

    // MARK: - Phase 2.5c Task 14: メタデータ遡及セクション

    @ViewBuilder
    private func metadataSection() -> some View {
        GroupBox("メタデータ") {
            VStack(alignment: .leading, spacing: 8) {
                Button("ファイル名からシリーズ・巻数を補完") {
                    guard let state = appState else {
                        recomputeResultMessage = "ライブラリが開いていません"
                        showRecomputeResult = true
                        return
                    }
                    do {
                        let count = try state.recomputeMetadataFromFilenames(undoManager: undoManager)
                        recomputeResultMessage = count == 0 ? "更新対象がありませんでした" : "\(count) 件を更新しました"
                        showRecomputeResult = true
                    } catch {
                        recomputeResultMessage = "エラー: \(error.localizedDescription)"
                        showRecomputeResult = true
                    }
                }
                Text("既存のシリーズ・巻数が空欄の本のみ、タイトル／ファイル名から自動推測して補完します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Button {
                    showRegenerationConfirm = true
                } label: {
                    Label("表紙を圧縮", systemImage: "arrow.down.circle")
                }
                .disabled(appState?.database == nil || bundleURL == nil)
                Text("上限 1200 px を超える表紙のみ圧縮します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .alert("補完完了", isPresented: $showRecomputeResult) {
            Button("OK") {}
        } message: {
            Text(recomputeResultMessage)
        }
    }

    // MARK: - Phase 2.8 B22: バックアップ セクション

    @ViewBuilder
    private func backupSection() -> some View {
        GroupBox("バックアップ") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("編集後にバックアップを保存", isOn: Binding(
                    get: { settings.backupEnabled },
                    set: { settings.backupEnabled = $0 }))

                Stepper(value: Binding(
                    get: { settings.backupGenerations },
                    set: { settings.backupGenerations = $0 }), in: 1...20) {
                    Text("保持する世代数: \(settings.backupGenerations)")
                }
                .disabled(!settings.backupEnabled)

                Divider()

                HStack {
                    Button("今すぐバックアップ") { performManualBackup() }
                        .disabled(appState?.database == nil || bundleURL == nil)
                    Button("整合性をチェック") { performIntegrityCheck() }
                        .disabled(appState?.database == nil)
                    Button("バックアップフォルダを表示") { openBackupsFolder() }
                        .disabled(bundleURL == nil)
                }

                Text("有効にすると、ウィンドウを閉じる際に変更があればバックアップを保存し、世代数を超えた古いものを削除します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func performManualBackup() {
        guard let db = appState?.database, let url = bundleURL else { return }
        try? BackupManager.makeBackup(from: db, bundleURL: url, timestamp: AppState.backupTimestamp())
        try? BackupManager.prune(in: BackupManager.backupsDir(for: url), keep: settings.backupGenerations)
    }

    private func performIntegrityCheck() {
        guard let db = appState?.database else { return }
        let rows = (try? db.integrityCheck()) ?? ["(エラー)"]
        let healthy = rows == ["ok"]
        let alert = NSAlert()
        alert.messageText = healthy
            ? "問題は見つかりませんでした"
            : "整合性の問題が見つかりました"
        // 正常時は SQLite の "ok" 行をそのまま見せない（メッセージで十分）。
        alert.informativeText = healthy ? "" : rows.prefix(20).joined(separator: "\n")
        alert.runModal()
    }

    private func openBackupsFolder() {
        guard let url = bundleURL else { return }
        NSWorkspace.shared.open(BackupManager.backupsDir(for: url))
    }

    // MARK: - Phase C-④b Task 4: 取り込み セクション（per-library override）

    @ViewBuilder
    private func importSection() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("このライブラリの取り込み設定")
                .font(.headline)
            Text("「グローバル既定に従う」を選ぶと、設定 ▸ 取り込み の値を使います。")
                .font(.caption).foregroundStyle(.secondary)

            // 本の種類を自動分類（3-way: 既定に従う / 有効 / 無効）
            VStack(alignment: .leading, spacing: 6) {
                Text("本の種類を自動分類")
                Picker("", selection: Binding(
                    get: {
                        switch settings.importAutoClassify {
                        case nil: return 0
                        case .some(true): return 1
                        case .some(false): return 2
                        }
                    },
                    set: { (sel: Int) in
                        settings.importAutoClassify = (sel == 0) ? nil : (sel == 1)
                    }
                )) {
                    Text("グローバル既定に従う（現在: \(ImportDefaults.globalAutoClassify() ? "有効" : "無効")）").tag(0)
                    Text("このライブラリで有効").tag(1)
                    Text("このライブラリで無効").tag(2)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // 厚い本の閾値（既定に従う / 上書き）
            let effectiveAuto = settings.importAutoClassify ?? ImportDefaults.globalAutoClassify()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("厚い本の閾値をグローバル既定に従う（現在: \(ImportDefaults.globalThickThreshold()) ページ）", isOn: Binding(
                    get: { settings.importThickThreshold == nil },
                    set: { inherit in
                        settings.importThickThreshold = inherit ? nil : ImportDefaults.globalThickThreshold()
                    }
                ))
                if settings.importThickThreshold != nil {
                    HStack {
                        Text("厚い本判定閾値（ページ数）")
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { settings.importThickThreshold ?? ImportDefaults.globalThickThreshold() },
                                set: { settings.importThickThreshold = max(5, min(100, $0)) }
                            ),
                            in: 5...100, step: 1
                        ) {
                            Text("\(settings.importThickThreshold ?? ImportDefaults.globalThickThreshold())")
                                .monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                        .labelsHidden()
                    }
                }
            }
            .disabled(!effectiveAuto)
            .opacity(effectiveAuto ? 1.0 : 0.5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - B6: プリセット操作ヘルパー

    private func loadSelectedPreset() {
        guard let p = stagedPresets.first(where: { $0.id == selectedPresetID }) else { return }
        presetName = p.name
        formatString = p.format
        updatePreview(formatString)
    }
    private func updateSelectedPreset(name: String, format: String) {
        guard let i = stagedPresets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        stagedPresets[i].name = name
        stagedPresets[i].format = format
    }
    private func addPreset() {
        let p = FilenameFormatPreset(id: UUID().uuidString, name: "新規プリセット", format: "@title")
        stagedPresets.append(p)
        selectedPresetID = p.id
        loadSelectedPreset()
    }
    private func duplicatePreset() {
        guard let src = stagedPresets.first(where: { $0.id == selectedPresetID }) else { return }
        let p = FilenameFormatPreset(id: UUID().uuidString, name: src.name + " のコピー", format: src.format)
        stagedPresets.append(p)
        selectedPresetID = p.id
        loadSelectedPreset()
    }
    private func deletePreset() {
        let r = FilenameFormatPresetLogic.removing(id: selectedPresetID, presets: stagedPresets, defaultID: stagedDefaultID)
        stagedPresets = r.presets
        stagedDefaultID = r.defaultID
        selectedPresetID = stagedPresets.first?.id ?? ""
        loadSelectedPreset()
    }

    /// カーソル位置（または選択範囲）にトークンを挿入し、カーソルを挿入後の位置に移動する。
    private func insertToken(_ token: String) {
        let nsText = formatString as NSString
        let loc = max(0, min(cursorRange.location, nsText.length))
        let len = max(0, min(cursorRange.length, nsText.length - loc))
        let safeRange = NSRange(location: loc, length: len)
        formatString = nsText.replacingCharacters(in: safeRange, with: token) as String
        // Move cursor to just after the inserted token
        cursorRange = NSRange(location: loc + token.utf16.count, length: 0)
    }

    private func updatePreview(_ raw: String) {
        do {
            let format = try FilenameFormat(raw: raw)
            let overrides = settings.bookTypeLabelOverrides
            samplePreview = Self.sampleRecords.map { record in
                let name = FilenameFormatter.format(record, with: format, bookTypeLabels: overrides)
                return "  • \(name)"
            }
            formatError = nil
        } catch let error as FilenameFormat.ParseError {
            formatError = describe(error)
            samplePreview = []
        } catch {
            formatError = "構文エラー"
            samplePreview = []
        }
    }

    private func describe(_ e: FilenameFormat.ParseError) -> String {
        switch e {
        case .unknownToken(let raw): return "未知のトークン: \(raw)"
        case .unclosedBracket(let c): return "閉じていない括弧: \(c)"
        case .nestedBracket: return "括弧のネストはサポートされません"
        }
    }

    private func save() {
        guard formatError == nil else { return }
        // B6: プリセットと既定を反映（filenameFormat は setDefaultPreset 内で同期される）
        settings.filenameFormatPresets = stagedPresets
        settings.setDefaultPreset(id: stagedDefaultID)

        // ラベルカスタマイズ反映（ステージした内容を保存時のみ適用）
        if settings.customFieldLabels != stagedFieldLabels {
            settings.customFieldLabels = stagedFieldLabels
        }
        if settings.customBookTypeLabels != stagedBookTypeLabels {
            settings.customBookTypeLabels = stagedBookTypeLabels
        }

        // Lock 反映
        if !lockToggleOn {
            settings.lockPasswordHash = nil
            settings.lockPasswordSalt = nil
            settings.useBiometric = false
            BiometricArming.disarm(settings)
            if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
        } else if !passwordInput.isEmpty && passwordInput == passwordConfirm {
            // 新ハッシュで上書きする前に「新規設定 or 変更」を判定する。
            let isChange = settings.lockPasswordHash != nil
            let salt = LibraryLock.generateSalt()
            let hash = LibraryLock.computeHash(password: passwordInput, saltHex: salt)
            settings.lockPasswordHash = hash
            settings.lockPasswordSalt = salt
            settings.useBiometric = useBiometricInput
            settingsLogger.info("save: setting password hash, useBiometric=\(useBiometricInput), isChange=\(isChange)")
            if useBiometricInput && !isChange {
                // 新規設定: この Mac を即アーム（次回から生体のみで解錠。平文は保存しない＝armedHash は新ハッシュ）。
                BiometricArming.arm(settings, hash: hash)
            } else {
                // パスワード変更時（isChange）または生体認証 OFF: アーム解除。
                // 変更時は同一 Mac でも次回 1 回だけ新パスワードの再入力を求め、解錠シートの
                // requirePassword 経路（入力成功 → armThisMachine）で再アームされる。
                BiometricArming.disarm(settings)
            }
            if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
        } else if lockToggleOn && passwordInput.isEmpty {
            // 既存ロック保持、useBiometric だけ切替
            if useBiometricInput != settings.useBiometric {
                if useBiometricInput {
                    // ON にするにはパスワード再入力必要（アームにはハッシュ照合のため平文が要る）
                    let alert = NSAlert()
                    alert.messageText = "生体認証を有効にするには現在のパスワードを再入力してください"
                    alert.runModal()
                    useBiometricInput = false
                    return
                } else {
                    settings.useBiometric = false
                    BiometricArming.disarm(settings)
                    if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
                }
            }
        }

        appState?.reloadFolderWatcher()
        dismiss()
    }

    /// 3 件のダミーレコードでプレビュー (実 library が空でも表示できるように)
    /// 「ブラックジャックによろしく」(佐藤秀峰・著作権フリー宣言済) を使用。
    /// Row 1: 全フィールド埋め → format の全トークンが出力される
    /// Row 2: keywordB 欠落 → [@keywordB] ブロックが省略される効果を確認
    /// Row 3: title のみ  → 全ブラケットブロックが省略される効果を確認
    private static let sampleRecords: [BookRecord] = [
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第01巻",
            author: "佐藤秀峰",
            genre: "一般コミック",
            dateAdded: Date(),
            keywordA: "医療",
            keywordB: "名作"
        ),
        // keywordB は nil → [@keywordB] ブロックが省略される
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第02巻",
            author: "佐藤秀峰",
            genre: "一般コミック",
            dateAdded: Date(),
            keywordA: "医療"
        ),
        // author / genre / keyword すべて nil → ブラケットブロックがすべて省略される
        BookRecord(
            id: 0,
            title: "ブラックジャックによろしく 第03巻",
            dateAdded: Date()
        )
    ]
}

// TODO: Multi-window concern — all open library windows will respond to
// .openLibrarySettings notification and show sheets simultaneously.
// Proper key-window filtering (via NSWindow.didBecomeKeyNotification) should
// be added in a follow-up task once multi-window usage is more common.
