// SPDX-License-Identifier: MIT
import Foundation

/// 命名フォーマットの名前付きプリセット（per-library）。
public struct FilenameFormatPreset: Identifiable, Codable, Sendable, Equatable {
    public let id: String       // 安定 ID（UUID 文字列）。永続キー。
    public var name: String     // ユーザー命名
    public var format: String   // FilenameFormat の raw 文字列

    public init(id: String, name: String, format: String) {
        self.id = id; self.name = name; self.format = format
    }

    /// 一覧/Picker 表示名（name 空白のみなら format で代替）。
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? format : name
    }
}

/// プリセット集合の純ロジック（移行・既定解決・不変条件）。LibrarySettings から委譲。
public enum FilenameFormatPresetLogic {
    /// 既存単一フォーマットを1プリセット（既定）へ移行。
    public static func migrate(existingFormat: String, id: String)
        -> (presets: [FilenameFormatPreset], defaultID: String) {
        ([FilenameFormatPreset(id: id, name: "既定", format: existingFormat)], id)
    }

    /// 既定プリセットの format（無効/空なら先頭、空配列なら "@title"）。
    public static func defaultFormat(in presets: [FilenameFormatPreset], defaultID: String) -> String {
        if let p = presets.first(where: { $0.id == defaultID }) { return p.format }
        return presets.first?.format ?? "@title"
    }

    /// requested が有効ならそれ、無効なら先頭 id、空配列なら ""。
    public static func validatedDefaultID(presets: [FilenameFormatPreset], requested: String) -> String {
        if presets.contains(where: { $0.id == requested }) { return requested }
        return presets.first?.id ?? ""
    }

    /// id を削除（最後の1件は no-op）。既定を消したら先頭へ振替。
    public static func removing(id: String, presets: [FilenameFormatPreset], defaultID: String)
        -> (presets: [FilenameFormatPreset], defaultID: String) {
        guard presets.count > 1, presets.contains(where: { $0.id == id }) else { return (presets, defaultID) }
        let next = presets.filter { $0.id != id }
        let newDefault = (defaultID == id) ? (next.first?.id ?? "") : defaultID
        return (next, newDefault)
    }
}
