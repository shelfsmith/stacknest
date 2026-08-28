// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore
import StackroomFormat  // BookRecord

struct BookFileRenameSheet: View {
    let books: [BookRow]
    let presets: [FilenameFormatPreset]
    let initialPresetID: String
    let database: Database
    let onComplete: ([Int]) -> Void
    /// Custom bookType label overrides for WYSIWYG @type token rendering.
    /// Pass `LibrarySettings.bookTypeLabelOverrides`; defaults to canonical labels.
    var bookTypeLabelOverrides: [Int: String] = [:]
    /// シリーズごとの巻数の桁。**庫全体から引いた最大巻**を渡す（呼び出し側が用意する）。
    var volumeWidths: [String: Int] = [:]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPresetID: String = ""

    private var activeFormat: FilenameFormat {
        let raw = FilenameFormatPresetLogic.defaultFormat(
            in: presets,
            defaultID: selectedPresetID.isEmpty ? initialPresetID : selectedPresetID)
        return (try? FilenameFormat(raw: raw)) ?? (try! FilenameFormat(raw: "@title"))
    }

    private var plan: [RenamePlanRow] {
        BookRenamePlanner.plan(
            books: books.map { $0.toRecord() },
            format: activeFormat,
            bookTypeLabels: bookTypeLabelOverrides,
            volumeWidths: volumeWidths,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ファイル名を変更 (\(books.count) 件)")
                .font(.title2.bold())

            Picker("プリセット", selection: $selectedPresetID) {
                ForEach(presets) { p in Text(p.displayName).tag(p.id) }
            }
            .frame(maxWidth: 280)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plan, id: \.id) { row in
                        HStack(alignment: .top) {
                            if row.status != .ok && row.status != .unchanged {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading) {
                                Text(row.oldName)
                                    .font(.caption.monospaced())
                                Text("→ \(row.newName)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(row.status != .ok && row.status != .unchanged ? .orange : .primary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            Text("コロン (:) は ： に自動変換。同名が既にある・名前を作れない・長すぎる項目はスキップされます")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("一括変更") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 400)
        .onAppear { if selectedPresetID.isEmpty { selectedPresetID = initialPresetID } }
    }

    private func apply() {
        // ★ 計画は 1 度だけ評価する。`plan` は計算プロパティで毎回ディスクを見るため、
        //   改名を実行した後に読み直すと、成功した行が conflictExisting に化ける。
        let rows = plan
        let result = BookRenameExecutor.apply(rows: rows) { id, newPath in
            try database.updateBookPath(id: id, newPath: newPath)
        }
        onComplete(rows.filter { $0.status == .ok }.map(\.id))
        let alert = NSAlert()
        alert.messageText = "リネーム結果"
        var text = "\(result.applied) 件成功 / \(rows.count - result.applied) 件スキップ"
        if !result.failed.isEmpty {
            text += "\n\n失敗:\n" + result.failed.map { "・\($0.reason)" }.joined(separator: "\n")
        }
        alert.informativeText = text
        alert.runModal()
        dismiss()
    }
}

