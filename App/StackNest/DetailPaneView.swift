// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    /// 「Finder で表示」ボタンの表示可否。リモートはローカルにファイルが無いため false。
    var canShowFinder: Bool = true
    /// リモートのファイル拡張子（"zip"/""=フォルダ/nil=不明）。path が秘匿のリモートで
    /// 「ファイル形式」を表示するためサーバ由来の拡張子を注入する（ローカルは nil で path 由来）。
    var remoteFileExtension: String? = nil
    /// 4.2c-9: レートの編集可否（canEdit と分離・リモート R でも可＝共有評価）。nil なら canEdit 連動。
    var ratingEditable: Bool? = nil
    /// 4.2c-9: リモートのレート専用適用（R 可・(rating, bookIDs)）。nil ならローカル patch 経路。
    var onSetRating: ((Int, [Int]) -> Void)? = nil
    /// 4.2c-9: 未読の編集可否（canEdit と分離・リモート R でも可＝共有閲覧状態）。nil なら canEdit 連動。
    var unseenEditable: Bool? = nil
    /// 4.2c-9: リモートの未読専用適用（R 可・(unseen, bookIDs)）。nil ならローカル patch 経路。
    var onSetUnseen: ((Bool, [Int]) -> Void)? = nil
    /// 読む方向ピッカーの編集可否。canEdit と独立（R/O リモートでも /direction 経由で変更可）。
    let directionEditable: Bool
    /// 単一ブック時の読む方向変更を専用ルートへ流す closure（リモートは /direction へ）。
    /// nil ならローカル従来どおり onApplyPatch（DB 直書き）へフォールバック。
    let onSetPageDirection: ((Int, PageDirection?) -> Void)?
    let onApplyPatch: (Int, BookPatch) -> Void          // was applyPatch(bookID:patch:undoManager:)
    let onApplyPatchMulti: ([Int], BookPatch) -> Void   // was applyPatch(bookIDs:patch:undoManager:)
    let onSetCover: (String?, Int) async throws -> Void  // was setCoverImageName(_:for:undoManager:)
    let onClearCrop: (Int) -> Void                      // was updateBookCoverCropRect(id:json:nil)+refresh
    let onSetCrop: (Int, String) -> Void                // was updateBookCoverCropRect(id:json:<json>)+refresh
    let onJump: (DetailField, String) -> Void           // was jumpToFilterOrSearch(field:value:)
    let onError: (AppError) -> Void                     // was appState.error = <AppError>
    /// 4.2c-6b: リモート表紙編集用の注入（nil=ローカル＝従来 CoverPickerSheet）。
    var remoteCoverCandidates: ((Int) async -> (entries: [String], current: String?))? = nil
    var remoteEntryImage: ((Int, String) async -> NSImage?)? = nil
    /// G4a: 外部画像を表紙に設定（imageData, crop, bookID）。ローカルのみ注入・リモート/オフラインは nil。
    let onSetExternalCover: ((Data, CGRect?, Int) async -> Void)?

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
        canShowFinder: Bool = true,
        remoteFileExtension: String? = nil,
        ratingEditable: Bool? = nil,
        onSetRating: ((Int, [Int]) -> Void)? = nil,
        unseenEditable: Bool? = nil,
        onSetUnseen: ((Bool, [Int]) -> Void)? = nil,
        directionEditable: Bool = true,
        onSetPageDirection: ((Int, PageDirection?) -> Void)? = nil,
        onApplyPatch: @escaping (Int, BookPatch) -> Void,
        onApplyPatchMulti: @escaping ([Int], BookPatch) -> Void,
        onSetCover: @escaping (String?, Int) async throws -> Void,
        onClearCrop: @escaping (Int) -> Void,
        onSetCrop: @escaping (Int, String) -> Void,
        onJump: @escaping (DetailField, String) -> Void,
        onError: @escaping (AppError) -> Void,
        coverImage: ((Int) async -> NSImage?)? = nil,
        remoteCoverCandidates: ((Int) async -> (entries: [String], current: String?))? = nil,
        remoteEntryImage: ((Int, String) async -> NSImage?)? = nil,
        onSetExternalCover: ((Data, CGRect?, Int) async -> Void)? = nil
    ) {
        self.books = books
        self.librarySettings = librarySettings
        self.bundleURL = bundleURL
        self.loader = loader
        self.canEdit = canEdit
        self.canShowFinder = canShowFinder
        self.remoteFileExtension = remoteFileExtension
        self.ratingEditable = ratingEditable
        self.onSetRating = onSetRating
        self.unseenEditable = unseenEditable
        self.onSetUnseen = onSetUnseen
        self.directionEditable = directionEditable
        self.onSetPageDirection = onSetPageDirection
        self.onApplyPatch = onApplyPatch
        self.onApplyPatchMulti = onApplyPatchMulti
        self.onSetCover = onSetCover
        self.onClearCrop = onClearCrop
        self.onSetCrop = onSetCrop
        self.onJump = onJump
        self.onError = onError
        self.coverImage = coverImage
        self.remoteCoverCandidates = remoteCoverCandidates
        self.remoteEntryImage = remoteEntryImage
        self.onSetExternalCover = onSetExternalCover
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
    /// G4a: 外部画像を表紙に設定する導線の state（D&D / NSOpenPanel → crop シート）。
    @State private var externalImage: NSImage?
    @State private var externalImageData: Data?
    @State private var externalCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var externalCropWidth: Double = 1.0
    @State private var externalCropHeight: Double = 1.0
    @State private var showExternalCrop = false

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
                        // 4.2c-9: リモートは未読専用 POST（R 可）、ローカルは patch 経路。
                        if let onSetUnseen {
                            onSetUnseen(newValue, snapshotIDs)
                        } else {
                            applyBoolCaptured(newValue, patchKeyPath: \BookPatch.unseen,
                                              isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                        }
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
                        // 4.2c-9: リモートはレート専用 POST（R 可）、ローカルは従来の patch 経路。
                        if let onSetRating {
                            onSetRating(newValue, snapshotIDs)
                        } else {
                            applyIntCaptured(newValue, patchKeyPath: \BookPatch.rating,
                                             isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                        }
                    }
                    .disabled(!(ratingEditable ?? canEdit))
                    if snapshotIsMulti {
                        UnseenIndicator(
                            state: MixedValueState.from(snapshotBooks.map(\.unseen))
                        ) { newValue in
                            // 4.2c-9: リモートは未読専用 POST（R 可）、ローカルは patch 経路。
                            if let onSetUnseen {
                                onSetUnseen(newValue, snapshotIDs)
                            } else {
                                applyBoolCaptured(newValue, patchKeyPath: \BookPatch.unseen,
                                                  isMulti: snapshotIsMulti, singleID: snapshotSingleID, ids: snapshotIDs)
                            }
                        }
                        .disabled(!(unseenEditable ?? canEdit))
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
                    .disabled(!canEdit)
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
                    .disabled(!directionEditable)
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
                currentEditingField: $currentEditingField,
                isEditable: canEdit
            )
            .id("memo-\(fingerprint)")

            Divider()

            // Read-only metadata + Finder button (single only)
            if !snapshotIsMulti, let book = snapshotBooks.first {
                readOnlyMetadata(book: book)
                if canEdit && canShowFinder {
                    Divider()
                    Button {
                        revealInFinder(book: book)
                    } label: {
                        Label("Finder で表示", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
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
        // Single-select のみ jump ボタンを表示 (multi-select では絞り込み対象が曖昧なため非表示)。
        // canEdit に関わらず表示する: jump-to-filter は read-only viewer も使える browse 機能。
        // BrowseField に対応する field → Browser pane filter を上書き、対応なし → searchQuery fallback
        let jumpHandler: ((String) -> Void)? = snapshotIsMulti ? nil : { [fieldID] jumpTag in
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
            onJumpToFilter: jumpHandler,
            isEditable: canEdit
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
            isEditable: canEdit,
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
            currentEditingField: $currentEditingField,
            isEditable: canEdit
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
            if let onSetPageDirection {
                onSetPageDirection(id, value)
            } else {
                onApplyPatch(id, patch)
            }
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
                    Button("表紙を編集") {
                        showCoverPicker = true
                    }
                    .disabled(!isSingleSelection || !canEdit)
                    if onSetExternalCover != nil {
                        Button("外部画像を表紙に設定…") {
                            presentExternalImagePanel()
                        }
                        .disabled(!isSingleSelection || !canEdit)
                    }
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
                    // 選択確定の共通処理（cover write→crop write の atomicity はローカル/リモート共通）。
                    let onPicked: (String, CGRect?) -> Void = { entry, cropRect in
                        Task {
                            do {
                                try await onSetCover(entry, book.id)
                            } catch {
                                return
                            }
                            if let cropRect {
                                onSetCrop(book.id, BookRow.encodeCoverCropRect(cropRect))
                            } else {
                                onClearCrop(book.id)
                            }
                        }
                    }
                    // 4.2c-6b: remote プロバイダが注入されていればリモート用ピッカー、なければ従来ローカル。
                    if let cand = remoteCoverCandidates, let img = remoteEntryImage {
                        RemoteCoverPickerSheet(
                            book: book,
                            loadCandidates: { await cand(book.id) },
                            loadEntryImage: { await img(book.id, $0) },
                            onSelect: onPicked)
                    } else {
                        CoverPickerSheet(book: book, bundleURL: bundleURL, onSelect: onPicked)
                    }
                }
                // G4a: 外部画像ファイルの D&D（ローカル・単一選択・編集可のみ）。
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard onSetExternalCover != nil, canEdit, isSingleSelection else { return false }
                    return handleExternalImageDrop(providers: providers)
                }
                // G4a: 外部画像のクロップ → 表紙設定シート。
                .sheet(isPresented: $showExternalCrop) {
                    externalCropSheet(bookID: book.id)
                }
            HStack(spacing: 6) {
                UnseenIndicator(state: unseenState, onCommit: onUnseenCommit)
                    .disabled(!(unseenEditable ?? canEdit))   // 4.2c-9: 未読は R でも可
                if let pages = book.pages {
                    Text("\(pages) ページ")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - G4a 外部画像 → 表紙

    /// D&D で受けた最初の画像ファイル URL を読み込みクロップシートを開く。非画像は無視。
    private func handleExternalImageDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                loadExternalImage(from: url)
            }
        }
        return true
    }

    /// NSOpenPanel で画像ファイルを選び、クロップシートを開く。
    private func presentExternalImagePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            loadExternalImage(from: url)
        }
    }

    /// 画像 URL を読み込み、画像なら state に保持してクロップシートを開く。非画像は no-op。
    private func loadExternalImage(from url: URL) {
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return }
        externalImageData = data
        externalImage = img
        externalCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        externalCropWidth = 1.0
        externalCropHeight = 1.0
        showExternalCrop = true
    }

    /// 外部画像のクロップ → 「設定」で onSetExternalCover を呼ぶシート。
    @ViewBuilder
    private func externalCropSheet(bookID: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外部画像を表紙に設定")
                .font(.title2.bold())
            Text("表示する範囲をドラッグで指定します（元のアーカイブは変更されません）")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let img = externalImage {
                CoverCropPicker(image: img, normalizedRect: $externalCrop)
                    .frame(minWidth: 420, minHeight: 320)
                // CoverCropPicker は矩形の移動のみ。幅/高さはスライダで調整する（CoverPickerSheet と同方式）。
                HStack {
                    Text("幅")
                    Slider(value: $externalCropWidth, in: 0.1...1.0)
                        .onChange(of: externalCropWidth) { _, newValue in
                            var r = externalCrop
                            r.size.width = newValue
                            r.origin.x = min(r.origin.x, 1 - newValue)
                            externalCrop = r
                        }
                }
                HStack {
                    Text("高さ")
                    Slider(value: $externalCropHeight, in: 0.1...1.0)
                        .onChange(of: externalCropHeight) { _, newValue in
                            var r = externalCrop
                            r.size.height = newValue
                            r.origin.y = min(r.origin.y, 1 - newValue)
                            externalCrop = r
                        }
                }
                HStack {
                    Button("リセット (全体)") {
                        externalCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
                        externalCropWidth = 1
                        externalCropHeight = 1
                    }
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { showExternalCrop = false }
                    .keyboardShortcut(.cancelAction)
                Button("設定") {
                    guard let data = externalImageData else { return }
                    let crop = externalCrop
                    Task {
                        await onSetExternalCover?(data, crop, bookID)
                        showExternalCrop = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(externalImageData == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
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
        // リモートは path が nil（秘匿）なのでサーバ由来の拡張子を優先。ローカルは path から算出。
        let ext: String
        if let remoteFileExtension {
            ext = remoteFileExtension
        } else if let path = book.path {
            ext = (path as NSString).pathExtension.lowercased()
        } else {
            return "—"
        }
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
