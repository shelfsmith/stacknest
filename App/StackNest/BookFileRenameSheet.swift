// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore
import StackroomFormat  // BookRecord

struct BookFileRenameSheet: View {
    let books: [BookRow]
    let format: FilenameFormat
    let database: Database
    let onComplete: ([Int]) -> Void
    /// Custom bookType label overrides for WYSIWYG @type token rendering.
    /// Pass `LibrarySettings.bookTypeLabelOverrides`; defaults to canonical labels.
    var bookTypeLabelOverrides: [Int: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private struct PreviewRow: Identifiable {
        let id: Int  // book ID
        let oldName: String
        let newName: String
        let conflict: Bool
        let url: URL
        let newURL: URL
    }

    private var previews: [PreviewRow] {
        var seen: Set<String> = []
        return books.map { book -> PreviewRow in
            let url = URL(fileURLWithPath: book.path ?? "")
            let ext = url.pathExtension
            let oldName = url.lastPathComponent
            let bookRecord = book.toRecord()
            let baseName = FilenameFormatter.format(bookRecord, with: format, bookTypeLabels: bookTypeLabelOverrides)
            let finalName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
            let newURL = url.deletingLastPathComponent().appendingPathComponent(finalName)
            let exists = FileManager.default.fileExists(atPath: newURL.path) && newURL.path != url.path
            let dup = !seen.insert(newURL.path).inserted
            return PreviewRow(
                id: book.id, oldName: oldName, newName: finalName,
                conflict: exists || dup, url: url, newURL: newURL
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ファイル名を変更 (\(books.count) 件)")
                .font(.title2.bold())

            Text("フォーマット: \(format.raw)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(previews) { row in
                        HStack(alignment: .top) {
                            if row.conflict {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading) {
                                Text(row.oldName)
                                    .font(.caption.monospaced())
                                Text("→ \(row.newName)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(row.conflict ? .orange : .primary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            Text("コロン (:) は ： に自動変換、衝突する項目はスキップされます")
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
    }

    private func apply() {
        var renamed: [Int] = []
        for row in previews {
            guard !row.conflict else { continue }
            do {
                try FileManager.default.moveItem(at: row.url, to: row.newURL)
                try database.updateBookPath(id: row.id, newPath: row.newURL.path)
                renamed.append(row.id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "\(row.oldName) のリネームに失敗しました"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        onComplete(renamed)
        let alert = NSAlert()
        alert.messageText = "リネーム結果"
        alert.informativeText = "\(renamed.count) 件成功 / \(previews.count - renamed.count) 件スキップ"
        alert.runModal()
        dismiss()
    }
}

// MARK: - BookRow → BookRecord conversion

private extension BookRow {
    func toRecord() -> BookRecord {
        BookRecord(
            id: id,
            title: title,
            author: author,
            genre: genre,
            path: path,
            dateAdded: dateAdded,
            playDate: playDate,
            bookType: bookType,
            fileType: fileType,
            pages: pages,
            myRate: rating,
            unseen: unseen,
            keywordA: keywordA,
            keywordB: keywordB,
            keywordC: keywordC,
            neta: neta
        )
    }
}
