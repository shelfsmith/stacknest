// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit  // for NSAlert / NSWorkspace (backup section)
import AppCore
import LibraryStore
import StackroomFormat  // for BookRecord
import OSLog

private let settingsLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibrarySettingsSheet")

/// G27a task 8: `LibrarySettings.setLock`/`clearLock` の compare-and-set が期待値不一致で
/// false を返したとき（＝検証に使った資格情報が既に古い＝他者が同時に変更/解除した）に使う
/// 表示用エラー。DB エラーとは区別したメッセージを出すためだけの薄いラッパ。
private struct LockConflictError: LocalizedError {
    var errorDescription: String? {
        "他の操作でロック設定が変更されたため、書き込みを中止しました。設定を開き直してもう一度お試しください。"
    }
}

struct LibrarySettingsSheet: View {
    @Bindable var settings: LibrarySettings
    let bundleName: String
    let bundleURL: URL?
    var appState: AppState? = nil
    // G27a Task6: confirmChangeLock()（LibrarySettingsSheet+Lock.swift）から dismiss() を
    // 呼ぶため、fileprivate ではなく internal にする（既存の private のままでは cross-file で
    // 見えない）。
    @Environment(\.dismiss) var dismiss
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
    // G27a Task6: パスワード変更にも現パスワード確認を要求する（解除と同じ非対称性の解消）。
    // 既存の confirmingDisableLock/disableLockPassword と同じ流儀（別 state・同じ見た目のシート）。
    @State var confirmingChangeLock = false
    @State var changeLockPasswordInput = ""
    @State var changeLockError: String? = nil

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

    // Phase G39: Finder タグと同期する項目（`""` = 同期しない）。
    // **ステージしない**（選んだ時点で DB に書き、前回同期値を全消しする）。理由は
    // `LibrarySettingsSheet+FinderTags.swift` の冒頭コメント。
    @State var finderTagField: String = LibrarySettingsSheet.finderTagSyncNoneTag

    /// 現在表示中の設定タブ (0=一般 / 1=フォーマット / 5=取り込み / 2=ラベル / 3=ロック / 4=監視フォルダ)。
    @State private var settingsTab = 0
    /// C-④b: 取り込みタブの厚さ閾値 override 直接入力用（グローバル設定と同様の TextField+Stepper）。
    @State private var importThresholdInput: String = ""

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        importSection()
                        watchSection()
                    }
                    .padding(16)
                }
                    .tabItem { Label("取り込み", systemImage: "tray.and.arrow.down") }
                    .tag(5)
                ScrollView { labelSection().padding(16) }
                    .tabItem { Label("ラベル", systemImage: "tag") }
                    .tag(2)
                ScrollView { lockSection().padding(16) }
                    .tabItem { Label("ロック", systemImage: "lock") }
                    .tag(3)
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
            finderTagField = appState?.finderTagSyncField ?? Self.finderTagSyncNoneTag
        }
        .confirmationDialog(
            "全ての表紙を再生成します",
            isPresented: $showRegenerationConfirm,
            titleVisibility: .visible
        ) {
            Button("再生成 (\(bookCount) 件)") {
                startRegeneration()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("全ての表紙を元ファイルから作り直します（1200 px を超えるものは縮小されます）。手動で選んだ表紙・アップロードした表紙は変更されません。続行しますか?")
        }
        .sheet(isPresented: Binding(
            get: { regenerationTask != nil && !showRegenerationResult },
            set: { _ in }
        )) {
            VStack(spacing: 16) {
                Text("表紙を再生成中…").font(.headline)
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
        .alert("再生成完了", isPresented: $showRegenerationResult) {
            Button("OK") { regenerationTask = nil }
        } message: {
            Text(String(format: "%d 件を再生成しました（約 %.1f MB 削減）",
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
        finderTagSection()   // Phase G39
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
                    Label("表紙を再生成", systemImage: "arrow.down.circle")
                }
                .disabled(appState?.database == nil || bundleURL == nil)
                Text("全ての表紙を元ファイルから作り直します（手動・アップロードした表紙は対象外）。")
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
                    Button("データベースを検査") { performIntegrityCheck() }
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
        // fix round 4 (Minor, whole-branch review): 「整合性」は本フェーズで蔵書ファイルの
        // 破損チェックの語彙として使われるようになったため、DB 検査（このボタンは既に
        // 「データベースを検査」に改名済み）側の文言からも紛らわしい単語を落とす。
        // リモート版の同機能（`RemoteLibrarySettingsSheet.swift` の alert title「データベース検査結果」）
        // と揃えた。
        alert.messageText = healthy
            ? "問題は見つかりませんでした"
            : "データベースに問題が見つかりました"
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
        GroupBox("自動分類") {
        VStack(alignment: .leading, spacing: 12) {
            Text("「既定に従う」を選ぶと、StackNest 設定の値を使います。")
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
                    Text("既定に従う（現在: \(ImportDefaults.globalAutoClassify() ? "有効" : "無効")）").tag(0)
                    Text("このライブラリで有効").tag(1)
                    Text("このライブラリで無効").tag(2)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            // 厚い本の閾値（既定に従う / 上書き）
            let effectiveAuto = settings.importAutoClassify ?? ImportDefaults.globalAutoClassify()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("厚い本の閾値を既定に従う（現在: \(ImportDefaults.globalThickThreshold()) ページ）", isOn: Binding(
                    get: { settings.importThickThreshold == nil },
                    set: { inherit in
                        if inherit {
                            settings.importThickThreshold = nil
                        } else {
                            let v = ImportDefaults.globalThickThreshold()
                            settings.importThickThreshold = v
                            importThresholdInput = String(v)
                        }
                    }
                ))
                if settings.importThickThreshold != nil {
                    // グローバル設定（設定 ▸ 取り込み）と同じ TextField 直接入力＋Stepper。
                    HStack {
                        Text("厚い本判定閾値（ページ数）")
                        Spacer()
                        TextField("", text: $importThresholdInput)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .onChange(of: importThresholdInput) { _, newValue in
                                let cleaned = String(newValue.filter(\.isNumber).prefix(3))
                                if cleaned != newValue { importThresholdInput = cleaned }
                            }
                            .onSubmit { commitImportThresholdInput() }
                        Stepper("", value: Binding(
                            get: { settings.importThickThreshold ?? ImportDefaults.globalThickThreshold() },
                            set: { settings.importThickThreshold = max(5, min(100, $0)) }
                        ), in: 5...100, step: 1)
                        .labelsHidden()
                    }
                    .onChange(of: settings.importThickThreshold) { _, newValue in
                        // Stepper 経由などで値が変わったら TextField を同期。
                        if let v = newValue, importThresholdInput != String(v) {
                            importThresholdInput = String(v)
                        }
                    }
                }
            }
            .disabled(!effectiveAuto)
            .opacity(effectiveAuto ? 1.0 : 0.5)
            .onAppear {
                if let v = settings.importThickThreshold { importThresholdInput = String(v) }
            }
        }
        .padding(8)
        }
    }

    /// C-④b: 取り込みタブの閾値 TextField をコミット（グローバル設定の commitThresholdInput 相当）。
    private func commitImportThresholdInput() {
        if let v = Int(importThresholdInput) {
            settings.importThickThreshold = max(5, min(100, v))
        }
        // 空/非数値は現在値へ戻す。
        importThresholdInput = String(settings.importThickThreshold ?? ImportDefaults.globalThickThreshold())
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
            formatError = Self.describe(error)
            samplePreview = []
        } catch {
            formatError = "構文エラー"
            samplePreview = []
        }
    }

    static func describe(_ e: FilenameFormat.ParseError) -> String {
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
        var labelsChanged = false
        if settings.customFieldLabels != stagedFieldLabels {
            settings.customFieldLabels = stagedFieldLabels
            labelsChanged = true
        }
        if settings.customBookTypeLabels != stagedBookTypeLabels {
            settings.customBookTypeLabels = stagedBookTypeLabels
            labelsChanged = true
        }
        // G8a Task 6: ホストローカルなラベル定義編集を共有 EventHub へ橋渡し。
        if labelsChanged, let uuid = settings.libraryUUID {
            ServerController.shared.publishLiveEvent(.settingsChanged(library: uuid))
        }

        // Lock 反映
        if !lockToggleOn {
            // G25c: salt/hash は組でまとめて消す（片方だけ残る中間状態を作らない）。
            // **書き込みの成功を後続の状態変更の前提にする** — 失敗を握り潰すと、UI 上は解除できたのに
            // DB にはロックが残り、生体設定と Keychain だけ消えた不整合になる。
            //
            // G27a task 8: 実際にロックが存在するときだけ compare-and-set で消す（存在しなければ
            // 消す物が無いので呼ばない）。`expectedHash` はこの時点でメモリにある hash ―― トグルを
            // 通した変更（confirmDisableLock 経由）はパスワード確認込みで既にメモリを揃えているので、
            // ここで再度パスワードを求める必要はない。外部が同時にロックを変更/解除していた場合だけ
            // CAS が不一致で弾く（DB は変更されない）。
            if let currentHash = settings.lockPasswordHash {
                do {
                    guard try settings.clearLock(expectedHash: currentHash) else {
                        settingsLogger.error("clearLock rejected: expected hash is stale (concurrent change)")
                        presentLockWriteFailure(LockConflictError())
                        appState?.reloadFolderWatcher()
                        return
                    }
                } catch {
                    settingsLogger.error("clearLock failed: \(error.localizedDescription, privacy: .public)")
                    presentLockWriteFailure(error)
                    // ロック以外の設定はここより前で永続化済み。ウォッチャーだけ取り残さないよう
                    // 成功時と同じく再構成してから抜ける（シートは閉じない＝再試行できる）。
                    appState?.reloadFolderWatcher()
                    return
                }
            }
            settings.useBiometric = false
            BiometricArming.disarm(settings)
            if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
        } else if !passwordInput.isEmpty && passwordInput == passwordConfirm {
            // 新ハッシュで上書きする前に「新規設定 or 変更」を判定する。
            let isChange = settings.lockPasswordHash != nil
            if isChange {
                // G27a Task6: 既存ロックの変更には現パスワードの確認が必須（無検証で上書きできると、
                // 解錠済みの端末を離席中に第三者がパスワードを差し替えて所有権を奪える）。
                // ここまでのロック以外の設定は既に永続化済み。シートは閉じず確認シートへ進み、
                // 実際の書き込みは confirmChangeLock() が検証成功後に行う。
                changeLockPasswordInput = ""
                changeLockError = nil
                confirmingChangeLock = true
                appState?.reloadFolderWatcher()
                return
            }
            // 新規施錠: 「hash キーがまだ存在しない」ことを条件にする（G27a task 8）。
            guard applyNewLock(isChange: false, expectedHash: nil) else { return }
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

    /// G27a Task6: ロック変更（既存ロックの上書き）が許可されるかを判定する純粋関数。
    /// View の `@State` から独立している（`self` を参照しない・すべて明示引数）ため、
    /// SwiftUI のホスティングコンテキスト外（ユニットテスト等）からも安全に呼べる。
    /// **切り出した理由**: `LibrarySettingsSheet` を直接構築して `@State` を手動で書き換えても、
    /// ライブビューヒエラルキーにマウントされていないと書き込みが後続のメソッド呼び出しへ
    /// 反映されないことを実装中に実測した（SwiftUI の未サポート挙動）。判定ロジック自体を
    /// `@State` から切り離すことでテスト可能にする。
    ///
    /// 既存ロックが本当に無ければ（`existingHash`・`existingSalt` の**両方**が nil）無条件に許可する
    /// （新規設定は現パスワード不要のまま）。既存ロックがあれば `currentPasswordInput` を
    /// `LibraryLock.verify` で検証する（定数時間比較を保つため自前比較は書かない）。
    /// 片方だけ nil（本来 setLock/clearLock は組で書くので想定外の中間状態）はフェイルセーフに
    /// 倒して拒否する（無条件許可の対象を「本当に未設定」だけに絞る）。
    /// `nonisolated`: `self` にも他の MainActor 状態にも触れない純粋関数なので、
    /// `LibrarySettingsSheet`（View）の暗黙 `@MainActor` 隔離から明示的に外す
    /// （外さないとテストの nonisolated コンテキストからの呼び出しが Swift 6 で警告になる）。
    nonisolated static func lockChangeIsAuthorized(existingHash: String?, existingSalt: String?,
                                                    currentPasswordInput: String) -> Bool {
        if existingHash == nil && existingSalt == nil { return true }
        guard let existingHash, let existingSalt else { return false }
        return LibraryLock.verify(password: currentPasswordInput, saltHex: existingSalt, against: existingHash)
    }

    /// 新しいロックを DB へ書き込む（新規設定・変更の両方で共有する実処理）。
    /// `passwordInput`（ロックタブでステージ済みの新パスワード）を使う。呼び出し側は
    /// **変更の場合、事前に現パスワードの検証を済ませてから**呼ぶこと（本関数自身は検証しない）。
    /// `isChange` は生体アームの分岐にのみ使う（変更時は同一 Mac でも次回 1 回だけ新パスワードの
    /// 再入力を求め、解錠シートの requirePassword 経由で再アームさせる）。
    /// - Parameter expectedHash: 書き込み時点で DB 上にあるべき hash（G27a task 8・compare-and-set）。
    ///   新規施錠は `nil`（「まだ存在しない」ことを条件にする）。変更は呼び出し側が検証に使った hash。
    /// - Returns: 書き込みに成功したか。false のとき、呼び出し側はシートを閉じずに抜けること
    ///   （presentLockWriteFailure 済み・ウォッチャーは本関数内で再構成済み）。
    @discardableResult
    func applyNewLock(isChange: Bool, expectedHash: String?) -> Bool {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: passwordInput, saltHex: salt)
        // G25c: 設定シートでの施錠は「本人がパスワードを知っている証明」とみなし、この窓は解錠済みとする。
        // **ハッシュ代入より前に立てる**こと(後だと「施錠済み && 未解錠」が一瞬成立し、
        // live 導出になったゲートが解錠シートを出してしまう)。
        // G25c: salt/hash は組でまとめて書く（別々だと外部変更と交錯して不整合が残りうる）。
        // **書き込みが成功してから**「この窓は解錠済み」と記録する。先に記録すると、
        // 書き込み失敗時に DB に存在しないハッシュを「検証済み」として保持してしまう。
        do {
            guard try settings.setLock(hash: hash, salt: salt, expectedHash: expectedHash) else {
                // G27a task 8: 検証に使った資格情報（または「未施錠」という前提）が既に古い。
                settingsLogger.error("setLock rejected: expected hash is stale (concurrent change)")
                presentLockWriteFailure(LockConflictError())
                appState?.reloadFolderWatcher()
                return false
            }
        } catch {
            settingsLogger.error("setLock failed: \(error.localizedDescription, privacy: .public)")
            presentLockWriteFailure(error)
            // 同上: ロック以外の設定は永続化済みなのでウォッチャーを再構成してから抜ける。
            appState?.reloadFolderWatcher()
            return false
        }
        // 設定シートでの施錠は「本人がパスワードを知っている証明」とみなし、この窓は解錠済みとする。
        appState?.markUnlocked(hash: hash)
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
        return true
    }

    /// G25c: ロックの書き込みに失敗したことを伝える。シートは閉じない（利用者が再試行できるように）。
    private func presentLockWriteFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ロック設定を保存できませんでした"
        alert.informativeText = "データベースに書き込めませんでした。時間をおいて再度お試しください。\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 3 件のダミーレコードでプレビュー (実 library が空でも表示できるように)
    /// 「ブラックジャックによろしく」(佐藤秀峰・著作権フリー宣言済) を使用。
    /// Row 1: 全フィールド埋め → format の全トークンが出力される
    /// Row 2: keywordB 欠落 → [@keywordB] ブロックが省略される効果を確認
    /// Row 3: title のみ  → 全ブラケットブロックが省略される効果を確認
    static let sampleRecords: [BookRecord] = [
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
