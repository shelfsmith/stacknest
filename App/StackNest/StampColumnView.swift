// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Stamp pane の 1 列 (1 StampField 分)。
/// ヘッダ + [消去] chip + 値 chip 群 + [+ 新規追加] chip。
/// chip クリック時は appState.selectedBookIDs に対して bulk apply。
struct StampColumnView: View {
    let field: StampField
    @Bindable var appState: AppState
    @State private var values: [String] = []
    @State private var showAddPopover = false
    @State private var newValueText = ""
    @Environment(\.undoManager) private var undoManager

    private var refreshTrigger: String {
        let defsCount = appState.librarySettings?.stampDefinitions[field.dbColumn]?.count ?? 0
        return "\(field.dbColumn)|defs=\(defsCount)|books=\(appState.booksDataVersion)"
    }

    private var isAnyBookSelected: Bool {
        !appState.selectedBookIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.librarySettings?.stampLabel(for: field) ?? field.localizedTitle)
                .font(.subheadline.bold())
                .padding(.horizontal, 6)
                .padding(.top, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ChipView(variant: .clear, disabled: !isAnyBookSelected) {
                        applyClear()
                    }
                    ForEach(values, id: \.self) { v in
                        ChipView(variant: .value(v), disabled: !isAnyBookSelected) {
                            applyValue(v)
                        }
                    }
                    // O2-2: [+ 新規追加] は library のスタンプ定義を追加するのみ。
                    // book を変更しないので 0 件選択時でも常時有効にする。
                    ChipView(variant: .newAdd, disabled: false) {
                        showAddPopover = true
                    }
                    .popover(isPresented: $showAddPopover) {
                        newValuePopoverContent()
                    }
                }
                .padding(6)
            }
        }
        .task(id: refreshTrigger) {
            await loadValues()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func newValuePopoverContent() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新しい \(appState.librarySettings?.stampLabel(for: field) ?? field.localizedTitle) を追加")
                .font(.caption.bold())
            TextField("", text: $newValueText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { addNewValue() }
            HStack {
                Button("キャンセル") {
                    newValueText = ""
                    showAddPopover = false
                }
                Spacer()
                Button("追加") {
                    addNewValue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newValueText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func loadValues() async {
        let defs = appState.librarySettings?.stampDefinitions[field.dbColumn] ?? []
        let sorted = defs.sorted()
        await MainActor.run { self.values = sorted }
    }

    /// StampField → BookPatch の対応する String? WritableKeyPath を返す。
    private var patchKeyPath: WritableKeyPath<BookPatch, String?> {
        switch field {
        case .genre:    return \BookPatch.genre
        case .neta:     return \BookPatch.neta
        case .keywordA: return \BookPatch.keywordA
        case .keywordB: return \BookPatch.keywordB
        case .keywordC: return \BookPatch.keywordC
        }
    }

    private func applyClear() {
        let ids = Array(appState.selectedBookIDs)
        guard !ids.isEmpty else { return }
        do {
            try appState.clearStampValue(
                patchKeyPath: patchKeyPath,
                bookIDs: ids,
                undoManager: undoManager
            )
        } catch {
            appState.error = .unexpected(error)
        }
    }

    private func applyValue(_ value: String) {
        guard let db = appState.database else { return }
        let ids = Array(appState.selectedBookIDs)
        guard !ids.isEmpty else { return }

        // 現在値スナップショット (undo に必要な prev 情報として PatchBooksCommand.prepare が使う)
        let allBooks = appState.displayedBooks
        var currentValues: [Int: String?] = [:]
        for id in ids {
            if let row = allBooks.first(where: { $0.id == id }) {
                switch field {
                case .genre:    currentValues[id] = row.genre
                case .neta:     currentValues[id] = row.neta
                case .keywordA: currentValues[id] = row.keywordA
                case .keywordB: currentValues[id] = row.keywordB
                case .keywordC: currentValues[id] = row.keywordC
                }
            }
        }

        do {
            try appState.applyStampValue(
                value,
                patchKeyPath: patchKeyPath,
                bookIDs: ids,
                database: db,
                currentValues: currentValues,
                undoManager: undoManager
            )
        } catch {
            appState.error = .unexpected(error)
        }
    }

    private func addNewValue() {
        let trimmed = newValueText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // 1. stampDefinitions に追加 (重複 skip)
        if let settings = appState.librarySettings {
            var defs = settings.stampDefinitions
            var fieldDefs = defs[field.dbColumn] ?? []
            if !fieldDefs.contains(trimmed) {
                fieldDefs.append(trimmed)
                defs[field.dbColumn] = fieldDefs
                settings.stampDefinitions = defs
                // refreshTrigger (defs count 変化) により .task が再起動し loadValues() が走る
            }
        }

        // 2. 選択中 book に append (既存の挙動を維持)
        applyValue(trimmed)

        newValueText = ""
        showAddPopover = false
    }
}
