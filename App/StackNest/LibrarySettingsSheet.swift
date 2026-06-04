// SPDX-License-Identifier: MIT
import SwiftUI
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("「\(bundleName)」 の設定")
                .font(.title2.bold())

            // ファイル名フォーマット section
            GroupBox("ファイル名フォーマット") {
                VStack(alignment: .leading, spacing: 8) {
                    CursorTrackingTextField(text: $formatString, selectedRange: $cursorRange)
                        .frame(height: 28)
                        .onChange(of: formatString) { _, new in updatePreview(new) }

                    HStack {
                        Menu("トークンを挿入") {
                            ForEach(FormatToken.allCases, id: \.self) { tok in
                                Button(tok.rawSyntax) {
                                    insertToken(tok.rawSyntax)
                                }
                            }
                        }
                        .frame(maxWidth: 160)
                        Spacer()
                    }

                    if let err = formatError {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Text("プレビュー:")
                        .font(.caption.bold())
                        .padding(.top, 4)
                    ForEach(Array(samplePreview.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("⚠ コロン (:) は ： に自動変換されます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            lockSection()

            labelSection()

            metadataSection()

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
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            formatString = settings.filenameFormat
            updatePreview(formatString)
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
        settings.filenameFormat = formatString

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
