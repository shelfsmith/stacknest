// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import LibraryStore
import AppCore
import ImageCache

struct DetailPaneView: View {
    let books: [BookRow]                    // was appState.displayedSelectedBooks
    let librarySettings: LibrarySettings?   // was appState.librarySettings
    let bundleURL: URL                      // was appState.bundleURL
    let loader: ThumbnailLoader?
    /// Optional cover-image provider for remote (read-only) clients.
    /// When non-nil, called instead of `loader` to fetch the cover NSImage over HTTP.
    /// Defaults to nil — local callers omit this and stay on the `loader` path.
    let coverImage: ((Int) async -> NSImage?)?
    let canEdit: Bool                       // local = true
    let onApplyPatch: (Int, BookPatch) -> Void          // was applyPatch(bookID:patch:undoManager:)
    let onApplyPatchMulti: ([Int], BookPatch) -> Void   // was applyPatch(bookIDs:patch:undoManager:)
    let onSetCover: (String?, Int) async throws -> Void  // was setCoverImageName(_:for:undoManager:)
    let onClearCrop: (Int) -> Void                      // was updateBookCoverCropRect(id:json:nil)+refresh
    let onSetCrop: (Int, String) -> Void                // was updateBookCoverCropRect(id:json:<json>)+refresh
    let onJump: (DetailField, String) -> Void           // was jumpToFilterOrSearch(field:value:)
    let onError: (AppError) -> Void                     // was appState.error = <AppError>

    /// 明示イニシャライザ。`coverImage` は inline default (`= nil`) を持つため
    /// 合成メモリワイズ init からは除外され、呼び出し側で渡せなくなる。
    /// リモート (read-only) クライアントが coverImage を注入できるよう、
    /// 末尾に default 付きで明示的に受け取る。ローカル呼び出しは従来どおり省略可。
    init(
        books: [BookRow],
        librarySettings: LibrarySettings?,
        bundleURL: URL,
        loader: ThumbnailLoader?,
        canEdit: Bool,
        onApplyPatch: @escaping (Int, BookPatch) -> Void,
        onApplyPatchMulti: @escaping ([Int], BookPatch) -> Void,
        onSetCover: @escaping (String?, Int) async throws -> Void,
        onClearCrop: @escaping (Int) -> Void,
        onSetCrop: @escaping (Int, String) -> Void,
        onJump: @escaping (DetailField, String) -> Void,
        onError: @escaping (AppError) -> Void,
        coverImage: ((Int) async -> NSImage?)? = nil
    ) {
        self.books = books
        self.librarySettings = librarySettings
        self.bundleURL = bundleURL
        self.loader = loader
        self.canEdit = canEdit
        self.onApplyPatch = onApplyPatch
        self.onApplyPatchMulti = onApplyPatchMulti
        self.onSetCover = onSetCover
        self.onClearCrop = onClearCrop
        self.onSetCrop = onSetCrop
        self.onJump = onJump
        self.onError = onError
        self.coverImage = coverImage
    }

    /// Bumped when title rejection happens, so EditableTextField gets a fresh
    /// @State and resets to the original (non-empty) title.
    @State private var titleResetTrigger: Int = 0
    /// Signal to start editing a specific field via Tab navigation.
    /// Parent sets this to the target field; the target's .onChange handler
    /// calls startEditing(), then parent resets to nil on the next runloop tick.
    @State private var requestedField: DetailField? = nil
    /// 現在編集中の field (= TabFocusController が Tab 消費判定に使う)。
    /// 各 field component が自身の `isEditing` の onChange で更新する。
    /// nil なら誰も編集していない = Tab pass-through。
    @State private var currentEditingField: DetailField? = nil
    /// requestedField が同じ値で連続 set されても各 field の onChange が発火するように
    /// bump される counter。advanceField/retreatField で +1 する。
    /// 旧実装は `requestedField = next; Task { requestedField = nil }` で nil リセット
    /// していたが、SwiftUI が同 runloop 内の `nil → X → nil` 変化を coalesce して
    /// onChange が発火しない race が Hackintosh で頻発 (2026-05-25 確認)。nil リセットを
    /// 撤去し、代わりに nonce 更新で「変化があった」ことを SwiftUI に伝える。
    @State private var requestedFieldNonce: Int = 0
    /// 表紙選択 sheet の表示フラグ (Task 8)
    @State private var showCoverPicker = false

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView(
                    "書籍が選択されていません",
                    systemImage: "book",
                    description: Text("グリッドから書籍を選択すると詳細が表示されます")
                )
            } else {
                ScrollView { content }
            }
        }
        .background(
            TabFocusController(
                currentEditingField: $currentEditingField,
                onTabNext: { from in advanceField(from: from) },
                onShiftTabPrev: { from in retreatField(from: from) }
            )
        )
        .onChange(of: currentEditingField) { old, new in
            TabFocusController.logger.info("currentEditingField: \(String(describing: old), privacy: .public) → \(String(describing: new), privacy: .public)")
        }
        .onChange(of: requestedField) { old, new in
            TabFocusController.logger.info("requestedField: \(String(describing: old), privacy: .public) → \(String(describing: new), privacy: .public)")
        }
    }

    @ViewBuilder
    private var content: some View {
        // Snapshot the selection at body-computation time so that closures
        // passed to editors capture these locals rather than reading from
        // appState dynamically. When a .id() teardown fires .onDisappear →
        // commit(), the closure still refers to the *old* selection — the
        // books that were selected when this body was last rendered — and
        // writes to the correct records even if the user has already clicked
        // a different book.
        let snapshotBooks = books
        let snapshotIsMulti = snapshotBooks.count > 1
        let snapshotSingleID: Int? = snapshotBooks.count == 1 ? snapshotBooks.first?.id : nil
        let snapshotIDs: [Int] = snapshotBooks.map(\.id)
        let fingerprint = snapshotIDs.sorted()

        VStack(alignment: .leading, spacing: 16) {
            if snapshotIsMulti {
                multiSelectHeader
                Divider()
            } else if let book = snapshotBooks.first {
                coverSection(
                    book: book,
                    unseenState: MixedValueState.from(snapshotBooks.map(\.unseen)),
                    onUnseenCommit: { newValue in
                        applyBoolCaptured(newValue, patchKeyPath: \BookPatch.unseen,
                                          isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                    }
                )
                Divider()
            }

            // Status rows centered (rating + bookType).
            // Single-select の UnseenIndicator は coverSection 内へ移動済 (表紙下のページ数横)。
            // Multi-select は cover が無いのでここで併置する。
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Spacer()
                    StarRatingPicker(state: intState(\BookRow.rating)) { newValue in
                        applyIntCaptured(newValue, patchKeyPath: \BookPatch.rating,
                                         isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                    }
                    if snapshotIsMulti {
                        UnseenIndicator(
                            state: MixedValueState.from(snapshotBooks.map(\.unseen))
                        ) { newValue in
                            applyBoolCaptured(newValue, patchKeyPath: \BookPatch.unseen,
                                              isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    Spacer()
                    BookTypePicker(
                        state: intState(\BookRow.bookType),
                        settings: librarySettings
                    ) { newValue in
                        applyIntCaptured(newValue, patchKeyPath: \BookPatch.bookType,
                                         isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    Spacer()
                    // Phase 2.6b-2 D3: per-book page direction picker
                    let pageDirectionState: MixedValueState<PageDirection?> = MixedValueState.from(
                        snapshotBooks.map { $0.pageDirection }
                    )
                    PageDirectionPicker(state: pageDirectionState) { newValue in
                        applyPageDirectionCaptured(newValue, isMulti: snapshotIsMulti,
                                                   singleID: snapshotSingleID, ids: snapshotIDs)
                    }
                    Spacer()
                }
            }

            Divider()

            // Title
            if !snapshotIsMulti, let book = snapshotBooks.first {
                titleFieldCaptured(book: book)
            } else if snapshotIsMulti {
                titleDisabledRow
            }

            // Tag fields — closures capture snapshot vars so teardown commits
            // go to the correct books.
            // Content fields use settings-resolved labels so custom names are reflected in real time.
            let ls = librarySettings
            tagFieldCaptured(tag: "author",   label: "作者",         keyPath: \BookRow.author,    patchKeyPath: \BookPatch.author,    fieldID: .author,   snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "keywordA", label: ls?.label(for: .keywordA) ?? "キーワード A", keyPath: \BookRow.keywordA,  patchKeyPath: \BookPatch.keywordA,  fieldID: .keywordA, snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "keywordB", label: ls?.label(for: .keywordB) ?? "キーワード B", keyPath: \BookRow.keywordB,  patchKeyPath: \BookPatch.keywordB,  fieldID: .keywordB, snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "keywordC", label: ls?.stampLabel(for: .keywordC) ?? "キーワード C", keyPath: \BookRow.keywordC,  patchKeyPath: \BookPatch.keywordC,  fieldID: .keywordC, snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "genre",    label: ls?.label(for: .genre) ?? "ジャンル",     keyPath: \BookRow.genre,     patchKeyPath: \BookPatch.genre,     fieldID: .genre,    snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "neta",     label: ls?.label(for: .neta) ?? "関連",         keyPath: \BookRow.neta,      patchKeyPath: \BookPatch.neta,      fieldID: .neta,     snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)
            tagFieldCaptured(tag: "series",   label: "シリーズ",     keyPath: \BookRow.series,    patchKeyPath: \BookPatch.series,    clearFlagKeyPath: \BookPatch.clearSeries, fieldID: .series,   snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)

            // Volume (巻数) — Double? field, rendered as numeric TextField
            volumeFieldCaptured(snapshotIsMulti: snapshotIsMulti, snapshotSingleID: snapshotSingleID, snapshotIDs: snapshotIDs, fingerprint: fingerprint)

            // Memo (multi-line) — closure captures snapshot vars
            EditableTextEditor(
                label: "メモ",
                state: stringState(\BookRow.memo),
                onCommit: { newValue in
                    applyTextCaptured(newValue, patchKeyPath: \BookPatch.memo,
                                      isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                },
                fieldID: .memo,
                requestedField: requestedField,
                requestedFieldNonce: requestedFieldNonce,
                currentEditingField: $currentEditingField
            )
            .id("memo-\(fingerprint)")

            Divider()

            // Read-only metadata + Finder button (single only)
            if !snapshotIsMulti, let book = snapshotBooks.first {
                readOnlyMetadata(book: book)
                Divider()
                Button {
                    revealInFinder(book: book)
                } label: {
                    Label("Finder で表示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    // MARK: - Tab navigation

    /// Advances focus to the next field in Tab order.
    /// requestedField = next + nonce += 1 で次 field の onChange を発火させる。
    /// nil リセットはしない (SwiftUI coalesce 回避)。
    private func advanceField(from current: DetailField) {
        let next = current.next
        TabFocusController.logger.info("advanceField: from=\(String(describing: current), privacy: .public) → requestedField=\(String(describing: next), privacy: .public), nonce=\(requestedFieldNonce + 1, privacy: .public)")
        requestedField = next
        requestedFieldNonce &+= 1
    }

    /// Retreats focus to the previous field in Shift+Tab order.
    private func retreatField(from current: DetailField) {
        let prev = current.previous
        TabFocusController.logger.info("retreatField: from=\(String(describing: current), privacy: .public) → requestedField=\(String(describing: prev), privacy: .public), nonce=\(requestedFieldNonce + 1, privacy: .public)")
        requestedField = prev
        requestedFieldNonce &+= 1
    }

    // MARK: - Captured helpers (closures carry snapshot IDs from content body)

    /// Tag field whose onCommit closure captures snapshot selection ids so
    /// teardown commits (.onDisappear) write to the correct books.
    /// clearFlagKeyPath: when non-nil and value is empty, uses the flag for explicit NULL
    /// (used for series field to support clearSeries).
    @ViewBuilder
    private func tagFieldCaptured(tag: String,
                                   label: String,
                                   keyPath: KeyPath<BookRow, String?>,
                                   patchKeyPath: WritableKeyPath<BookPatch, String?>,
                                   clearFlagKeyPath: WritableKeyPath<BookPatch, Bool>? = nil,
                                   fieldID: DetailField,
                                   snapshotIsMulti: Bool,
                                   snapshotSingleID: Int?,
                                   snapshotIDs: [Int],
                                   fingerprint: [Int]) -> some View {
        let state = stringState(keyPath)
        // Single-select のみ jump ボタンを表示 (multi-select では絞り込み対象が曖昧なため非表示)
        // BrowseField に対応する field → Browser pane filter を上書き、対応なし → searchQuery fallback
        let jumpHandler: ((String) -> Void)? = (snapshotIsMulti || !canEdit) ? nil : { [fieldID] jumpTag in
            onJump(fieldID, jumpTag)
        }
        EditableTextField(
            label: LocalizedStringKey(label),
            state: state,
            onCommit: { newValue in
                applyTextCaptured(newValue, patchKeyPath: patchKeyPath,
                                  clearFlagKeyPath: clearFlagKeyPath,
                                  isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
            },
            fieldID: fieldID,
            requestedField: requestedField,
            requestedFieldNonce: requestedFieldNonce,
            currentEditingField: $currentEditingField,
            onJumpToFilter: jumpHandler
        )
        .id("tag-\(tag)-\(fingerprint)")
    }

    /// Volume field (巻数, Double?) whose onCommit closure captures snapshot selection ids.
    /// Rendered as a numeric TextField; empty input commits nil (clears volume).
    @ViewBuilder
    private func volumeFieldCaptured(snapshotIsMulti: Bool,
                                      snapshotSingleID: Int?,
                                      snapshotIDs: [Int],
                                      fingerprint: [Int]) -> some View {
        let values = books.map { $0.volume }
        let state: MixedValueState<Double?> = MixedValueState.from(values)
        VolumeEditorField(
            state: state,
            fieldID: .volume,
            requestedField: requestedField,
            requestedFieldNonce: requestedFieldNonce,
            currentEditingField: $currentEditingField,
            onCommit: { newValue in
                applyDoubleCaptured(newValue, patchKeyPath: \BookPatch.volume,
                                    isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
            }
        )
        .id("volume-\(fingerprint)")
    }

    /// Title field whose onCommit closure captures the book id at body-render time.
    @ViewBuilder
    private func titleFieldCaptured(book: BookRow) -> some View {
        let capturedID = book.id
        EditableTextField(
            label: "タイトル",
            state: .unanimous(book.title),
            onCommit: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Reset error first so alert re-presents even if previous error was .titleRequired
                    DispatchQueue.main.async {
                        onError(.titleRequired)
                    }
                    titleResetTrigger &+= 1
                    return
                }
                onApplyPatch(capturedID, BookPatch(title: trimmed))
            },
            fieldID: .title,
            requestedField: requestedField,
            requestedFieldNonce: requestedFieldNonce,
            currentEditingField: $currentEditingField
        )
        .id("title-\(book.id)-\(titleResetTrigger)")
    }

    /// Apply a String? patch using captured selection ids (not live appState reads).
    /// Routes through PatchBooksCommand for Undo support (Task 15).
    /// When clearWhenEmpty is true and value is empty, uses clearSeries flag instead
    /// of storing empty string (enables explicit NULL for series field).
    private func applyTextCaptured(_ value: String,
                                    patchKeyPath: WritableKeyPath<BookPatch, String?>,
                                    clearFlagKeyPath: WritableKeyPath<BookPatch, Bool>? = nil,
                                    isMulti: Bool,
                                    singleID: Int?,
                                    ids: [Int]) {
        let patch: BookPatch
        if value.isEmpty, let clearKP = clearFlagKeyPath {
            // Explicit NULL clear via flag (series field)
            var p = BookPatch()
            p[keyPath: clearKP] = true
            patch = p
        } else {
            var p = BookPatch()
            p[keyPath: patchKeyPath] = value
            patch = p
        }
        if isMulti {
            onApplyPatchMulti(ids, patch)
        } else if let id = singleID {
            onApplyPatch(id, patch)
        }
    }

    /// Apply an Int patch using captured selection ids.
    /// Routes through PatchBooksCommand for Undo support (Task 15).
    private func applyIntCaptured(_ value: Int,
                                   patchKeyPath: WritableKeyPath<BookPatch, Int?>,
                                   isMulti: Bool,
                                   singleID: Int?,
                                   ids: [Int]) {
        var patch = BookPatch()
        patch[keyPath: patchKeyPath] = value
        if isMulti {
            onApplyPatchMulti(ids, patch)
        } else if let id = singleID {
            onApplyPatch(id, patch)
        }
    }

    /// Apply a Bool patch using captured selection ids.
    /// Routes through PatchBooksCommand for Undo support (Task 15).
    private func applyBoolCaptured(_ value: Bool,
                                    patchKeyPath: WritableKeyPath<BookPatch, Bool?>,
                                    isMulti: Bool,
                                    singleID: Int?,
                                    ids: [Int]) {
        var patch = BookPatch()
        patch[keyPath: patchKeyPath] = value
        if isMulti {
            onApplyPatchMulti(ids, patch)
        } else if let id = singleID {
            onApplyPatch(id, patch)
        }
    }

    /// Apply a PageDirection? patch using captured selection ids.
    /// nil value → clearPageDirection=true (explicit NULL; inherits global setting).
    /// non-nil → sets per-book override.
    private func applyPageDirectionCaptured(_ value: PageDirection?,
                                             isMulti: Bool,
                                             singleID: Int?,
                                             ids: [Int]) {
        let patch: BookPatch
        if let dir = value {
            patch = BookPatch(pageDirection: dir)
        } else {
            patch = BookPatch(clearPageDirection: true)
        }
        if isMulti {
            onApplyPatchMulti(ids, patch)
        } else if let id = singleID {
            onApplyPatch(id, patch)
        }
    }

    /// Apply a Double? patch using captured selection ids.
    /// Routes through PatchBooksCommand for Undo support (Task 15).
    /// nil value (empty input) uses clearVolume=true to explicitly set NULL in DB.
    private func applyDoubleCaptured(_ value: Double?,
                                      patchKeyPath: WritableKeyPath<BookPatch, Double?>,
                                      isMulti: Bool,
                                      singleID: Int?,
                                      ids: [Int]) {
        let patch: BookPatch
        if value == nil {
            // Explicit clear: use clearVolume flag to set NULL (not COALESCE no-op)
            patch = BookPatch(clearVolume: true)
        } else {
            var p = BookPatch()
            p[keyPath: patchKeyPath] = value
            patch = p
        }
        if isMulti {
            onApplyPatchMulti(ids, patch)
        } else if let id = singleID {
            onApplyPatch(id, patch)
        }
    }


    // MARK: - Sections

    @ViewBuilder
    private var multiSelectHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(books.count) 件選択中")
                .font(.headline)
            Text("変更は選択中の全件に適用されます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func coverSection(
        book: BookRow,
        unseenState: MixedValueState<Bool>,
        onUnseenCommit: @escaping (Bool) -> Void
    ) -> some View {
        // 単一選択かどうかを判定 (複数選択時は context menu 全項目 disabled)
        let isSingleSelection = books.count == 1
        VStack(alignment: .center, spacing: 8) {
            CoverImageView(book: book, loader: loader, coverImage: coverImage)
                .frame(maxWidth: 240, maxHeight: 340)
                .contextMenu {
                    Button("表紙を選択…") {
                        showCoverPicker = true
                    }
                    .disabled(!isSingleSelection || !canEdit)
                    Button("自動に戻す") {
                        Task {
                            // Phase 2.5g+h+i fixup v1: 表紙データを自動に戻すと同時に crop_rect も NULL に。
                            // cover write の成否に関わらず crop_rect は必ずクリアする（元の挙動）。
                            // CoverPickerSheet 経由とは異なり、こちらは try? で cover write を swallow し
                            // 常に onClearCrop まで到達する。
                            try? await onSetCover(nil, book.id)
                            onClearCrop(book.id)
                        }
                    }
                    // 既に自動 (coverImageName == nil) かつ crop_rect も nil の場合は完全に no-op のため disabled
                    .disabled(!isSingleSelection || !canEdit || (book.coverImageName == nil && book.coverCropRect == nil))
                }
                .sheet(isPresented: $showCoverPicker) {
                    CoverPickerSheet(book: book, bundleURL: bundleURL) { entry, cropRect in
                        Task {
                            // Phase 2.5h A18-ext: cover_image_name 書き込みと crop rect 書き込み。
                            // cover write が失敗したときは crop write をスキップして atomicity を保つ
                            // (元の setCoverImageName の throw 伝搬と同じ制御フロー)。
                            do {
                                try await onSetCover(entry, book.id)
                            } catch {
                                return
                            }
                            // cropRect == nil (=全体) のときは crop を NULL に戻す (onClearCrop)。
                            if let cropRect {
                                onSetCrop(book.id, BookRow.encodeCoverCropRect(cropRect))
                            } else {
                                onClearCrop(book.id)
                            }
                        }
                    }
                }
            HStack(spacing: 6) {
                UnseenIndicator(state: unseenState, onCommit: onUnseenCommit)
                if let pages = book.pages {
                    Text("\(pages) ページ")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleDisabledRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("タイトル").font(.caption).foregroundStyle(.secondary)
            Text("—")
                .foregroundStyle(.tertiary)
                .help("タイトルは複数選択時に編集できません")
        }
    }

    @ViewBuilder
    private func readOnlyMetadata(book: BookRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            dateRow(label: "登録した日", date: book.dateAdded)
            dateRow(label: "最後に読んだ日", date: book.playDate)
            fieldRow(label: "ファイル形式", value: fileFormatLabel(book))
        }
    }

    @ViewBuilder
    private func fieldRow(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func dateRow(label: LocalizedStringKey, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let d = date {
                Text(d, format: .dateTime.year().month().day())
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - State helpers

    /// Maps a `String?` BookRow field to a `MixedValueState<String>` for the editor.
    /// `nil` and `""` both render as empty TextField — the distinction is not preserved.
    /// Combined with the COALESCE-based UPDATE in Database.updateBook (which treats nil
    /// patch values as "leave unchanged"), this means a user cannot clear a tag/keyword
    /// field back to SQL NULL through the editor — they can only replace its content.
    /// Documented limitation; resolution tracked as a follow-up in Tables.swift.
    private func stringState(_ kp: KeyPath<BookRow, String?>) -> MixedValueState<String> {
        let values = books.map { $0[keyPath: kp] ?? "" }
        return MixedValueState.from(values)
    }

    private func intState(_ kp: KeyPath<BookRow, Int>) -> MixedValueState<Int> {
        MixedValueState.from(books.map { $0[keyPath: kp] })
    }

    private func fileFormatLabel(_ book: BookRow) -> String {
        guard let path = book.path else { return "—" }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "zip": return String(localized: "Zip アーカイブ")
        case "rar": return String(localized: "RAR アーカイブ")
        case "7z":  return String(localized: "7z アーカイブ")
        case "":    return String(localized: "フォルダ")
        default:    return ".\(ext)"
        }
    }

    private func revealInFinder(book: BookRow) {
        guard let path = book.path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// CoverImageView preserved as private nested type.
private struct CoverImageView: View {
    let book: BookRow
    let loader: ThumbnailLoader?
    /// Optional remote cover provider. When non-nil, used instead of `loader`.
    let coverImage: ((Int) async -> NSImage?)?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image = image {
                Image(decorative: Self.croppedDetailImage(image, rect: book.coverCropRect), scale: 1.0)
                    .resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(1.4, contentMode: .fit)
                    .overlay(
                        Image(systemName: "book.closed")
                            .resizable()
                            .scaledToFit()
                            .padding(30)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        // coverImageName / cover_crop_rect 変化時に view identity を更新して SwiftUI に強制再描画させる。
        // .task(id:) だけでは @State image 更新後も view が skip される場合がある。
        .id("\(book.id):\(book.coverImageName ?? ""):\(book.coverCropRect.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? "")")
        .task(id: "\(book.id):\(book.coverImageName ?? "")") {
            if let coverImage {
                // Remote path: fetch NSImage via injected provider, convert to CGImage.
                let nsImage = await coverImage(book.id)
                image = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            } else {
                // Local path: use ThumbnailLoader (unchanged behavior).
                image = await loader?.thumbnail(for: book.id, maxPixelSize: 600)
            }
        }
    }

    /// Phase 2.5h A18-ext: 横長カバー対応。BookCell と意図的に重複させ、3 つ目の消費者が現れたら共通 util に抽出する。
    private static func croppedDetailImage(_ image: CGImage, rect: CGRect?) -> CGImage {
        guard let rect, rect != CGRect(x: 0, y: 0, width: 1, height: 1) else {
            return image
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pixelRect = CGRect(
            x: rect.origin.x * w,
            y: rect.origin.y * h,
            width: rect.size.width * w,
            height: rect.size.height * h
        ).integral
        return image.cropping(to: pixelRect) ?? image
    }
}
