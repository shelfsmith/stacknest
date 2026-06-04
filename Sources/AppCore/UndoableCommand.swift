// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// 取り消し可能な book mutation の抽象。memento パターンで実装。
public protocol UndoableCommand {
    /// undo に必要な情報を保持し、forward 実行する。
    func perform(database: Database) throws
    /// memento を使って forward 実行を元に戻す。
    func undo(database: Database) throws
    /// UndoManager に登録する際のアクション名 (e.g., "5 件のライブラリから削除")。
    var actionName: String { get }
}

/// 「ライブラリから削除」を Undo 可能にする。memento = 削除前の BookRow 全情報。
public final class DeleteBooksCommand: UndoableCommand {
    public let bookIDs: [Int]
    public private(set) var snapshot: [BookRow]
    public var actionName: String { "\(bookIDs.count) 件のライブラリから削除" }

    private init(bookIDs: [Int], snapshot: [BookRow]) {
        self.bookIDs = bookIDs
        self.snapshot = snapshot
    }

    /// 削除前の状態を snapshot として取得。perform() / undo() の前提となる prepare ステップ。
    public static func prepare(bookIDs: [Int], database: Database) throws -> DeleteBooksCommand {
        let all = try database.fetchAllBooks()
        let snap = all.filter { bookIDs.contains($0.id) }
        return DeleteBooksCommand(bookIDs: bookIDs, snapshot: snap)
    }

    public func perform(database: Database) throws {
        for id in bookIDs {
            try database.deleteBook(id: id)
        }
    }

    public func undo(database: Database) throws {
        for row in snapshot {
            try database.restoreBook(row)
        }
    }
}

/// メタデータ編集 (Detail Pane / スタンプ / reverse parser) を Undo 可能にする。
/// memento = 各 book の patch 適用前の値を BookPatch で記録。
public final class PatchBooksCommand: UndoableCommand {
    public let patches: [(bookID: Int, patch: BookPatch)]
    public private(set) var previousValues: [Int: BookPatch]
    public var actionName: String { "\(patches.count) 件のメタデータ編集" }

    private init(patches: [(Int, BookPatch)], previousValues: [Int: BookPatch]) {
        self.patches = patches
        self.previousValues = previousValues
    }

    public static func prepare(
        patches: [(bookID: Int, patch: BookPatch)],
        database: Database
    ) throws -> PatchBooksCommand {
        let all = try database.fetchAllBooks()
        var prev: [Int: BookPatch] = [:]
        for (id, p) in patches {
            guard let row = all.first(where: { $0.id == id }) else { continue }
            prev[id] = makeReversePatch(row: row, forward: p)
        }
        return PatchBooksCommand(patches: patches, previousValues: prev)
    }

    public func perform(database: Database) throws {
        for (id, p) in patches {
            try database.updateBook(id: id, patch: p)
        }
    }

    public func undo(database: Database) throws {
        for (id, prev) in previousValues {
            try database.updateBook(id: id, patch: prev)
        }
    }

    /// forward patch で変更される field について、変更前の値を含む reverse patch を作る。
    /// nil field の book 値を空文字列に変換する規約 (COALESCE pattern では空文字列が NULL 区別となる)。
    /// series/volume は clearSeries/clearVolume も含めて NULL に戻す操作を正確に undo する。
    private static func makeReversePatch(row: BookRow, forward: BookPatch) -> BookPatch {
        var rev = BookPatch()
        if forward.title    != nil { rev.title    = row.title }
        if forward.author   != nil { rev.author   = row.author   ?? "" }
        if forward.genre    != nil { rev.genre    = row.genre    ?? "" }
        if forward.keywordA != nil { rev.keywordA = row.keywordA ?? "" }
        if forward.keywordB != nil { rev.keywordB = row.keywordB ?? "" }
        if forward.keywordC != nil { rev.keywordC = row.keywordC ?? "" }
        if forward.neta     != nil { rev.neta     = row.neta     ?? "" }
        if forward.memo     != nil { rev.memo     = row.memo     ?? "" }
        if forward.rating   != nil { rev.rating   = row.rating }
        if forward.unseen   != nil { rev.unseen   = row.unseen }
        if forward.bookType != nil { rev.bookType = row.bookType }
        // series: forward が値設定 or クリア → reverse は元の値 or NULL クリア
        if forward.series != nil || forward.clearSeries {
            if let s = row.series {
                rev.series = s
            } else {
                rev.clearSeries = true
            }
        }
        // volume: forward が値設定 or クリア → reverse は元の値 or NULL クリア
        if forward.volume != nil || forward.clearVolume {
            if let v = row.volume {
                rev.volume = v
            } else {
                rev.clearVolume = true
            }
        }
        // cover_image_name: forward が値設定 or クリア → reverse は元の値 or NULL クリア
        // ⌘Z 時に DB の cover_image_name が forward 前の値に正しく戻り、
        // AppState.undoPerform がこれを検出して thumbnail を再生成できるようにする。
        if forward.coverImageName != nil || forward.clearCoverImageName {
            if let c = row.coverImageName {
                rev.coverImageName = c
            } else {
                rev.clearCoverImageName = true
            }
        }
        return rev
    }
}
