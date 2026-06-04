// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import LibraryStore
import OSLog

@MainActor
public enum BookMoveCommand {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "BookMoveCommand")

    public struct MoveResult: @unchecked Sendable {
        public var moved: [Int] = []
        public var skippedConflict: [URL] = []
        public var failed: [(URL, Error)] = []
    }

    /// NSOpenPanel でフォルダ選択 → moveItem ループ → 結果サマリ alert。
    /// initial directory は books の先頭 1 件の親フォルダ。
    /// 選択 0 件なら no-op。
    public static func runMoveFlow(
        books: [(id: Int, sourceURL: URL)],
        database: Database
    ) {
        guard !books.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "ファイルの移動先"
        panel.message = "選択した本のファイルを移動するフォルダを選択してください。"
        panel.prompt = "移動"
        panel.directoryURL = books.first?.sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destFolder = panel.url else { return }

        let result = move(books: books, to: destFolder, database: database)
        showResultAlert(result, total: books.count)
    }

    /// 純粋ロジック (NSOpenPanel/alert なし)。テスト用 + runMoveFlow から呼ばれる。
    public static func move(
        books: [(id: Int, sourceURL: URL)],
        to destFolder: URL,
        database: Database
    ) -> MoveResult {
        var result = MoveResult()
        let fm = FileManager.default
        for (id, source) in books {
            let dest = destFolder.appendingPathComponent(source.lastPathComponent)
            if dest.standardizedFileURL == source.standardizedFileURL {
                continue  // no-op (同一ファイル)
            }
            if fm.fileExists(atPath: dest.path) {
                result.skippedConflict.append(source)
                continue
            }
            do {
                try fm.moveItem(at: source, to: dest)
                try database.updateBookPath(id: id, newPath: dest.path)
                result.moved.append(id)
            } catch {
                logger.warning("Move failed for \(source.lastPathComponent): \(error.localizedDescription)")
                result.failed.append((source, error))
            }
        }
        return result
    }

    private static func showResultAlert(_ result: MoveResult, total: Int) {
        let alert = NSAlert()
        alert.messageText = "\(total) 件中 \(result.moved.count) 件を移動しました"
        var lines: [String] = []
        if !result.skippedConflict.isEmpty {
            lines.append("・\(result.skippedConflict.count) 件は移動先に同名ファイルが存在したためスキップ")
        }
        if !result.failed.isEmpty {
            lines.append("・\(result.failed.count) 件はエラーで失敗")
        }
        if !lines.isEmpty {
            alert.informativeText = lines.joined(separator: "\n")
        }
        alert.runModal()
    }
}
