// SPDX-License-Identifier: MIT
import Foundation
import StackNestL10n

/// 命名フォーマットの名前付きプリセット（per-library）。
public struct FilenameFormatPreset: Identifiable, Codable, Sendable, Equatable {
    public let id: String       // 安定 ID（UUID 文字列）。永続キー。
    public var name: String     // ユーザー命名
    public var format: String   // FilenameFormat の raw 文字列

    public init(id: String, name: String, format: String) {
        self.id = id; self.name = name; self.format = format
    }

    /// 移行・フォールバックで付ける既定プリセットの名前（保存値・G55 で不変）。
    public static let seededDefaultName = "既定"  // l10n:ignore stored preset name seed (language-independent); display via displayName

    /// 一覧/Picker 表示名（name 空白のみなら format で代替）。
    /// G55: 名前がちょうど種まきの既定名なら現在の言語に訳す（保存値 `name` は変えない）。
    public var displayName: String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return format }
        return Self.displayName(forStoredName: name)
    }

    /// 保存された名前を画面表示用に変換する（G55）。種まきの既定名だけ訳し、他はそのまま。
    public static func displayName(forStoredName storedName: String) -> String {
        storedName == seededDefaultName ? L10n.text(seededDefaultName) : storedName
    }
}

/// プリセット集合の純ロジック（移行・既定解決・不変条件）。LibrarySettings から委譲。
public enum FilenameFormatPresetLogic {
    /// 既存単一フォーマットを1プリセット（既定）へ移行。
    public static func migrate(existingFormat: String, id: String)
        -> (presets: [FilenameFormatPreset], defaultID: String) {
        ([FilenameFormatPreset(id: id, name: "既定", format: existingFormat)], id)  // l10n:ignore stored preset name (persisted; user-renamable, parity with Grant labels)
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
