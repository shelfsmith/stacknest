// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// グラント管理 GUI の純ロジック（App の SwiftUI から呼ぶ・testable なので AppCore に置く）。
public enum GrantManagementLogic {
    /// GUI 一覧から除外する予約グラント ID（既定 R/RW は既存トークン UI・env-admin はヘッドレス用）。
    public static let reservedIDs: Set<String> = ["default-read", "default-edit", "env-admin"]

    /// ユーザー作成グラントのみを返す（予約 ID を除外・順序保持）。
    public static func customGrants(_ all: [Grant]) -> [Grant] {
        all.filter { !reservedIDs.contains($0.id) }
    }

    /// スコープの短い要約文字列（一覧表示用）。
    public static func scopeSummary(_ scope: GrantScope) -> String {
        switch scope {
        case .all: return "全ライブラリ"
        case .libraries(let ids): return "\(ids.count) 庫"
        }
    }

    /// 追加/編集シートの保存可否。ラベル非空(trim) かつ (全ライブラリ or 選択庫 >= 1)。
    public static func isValidInput(label: String, scopeIsAll: Bool, selectedLibraryCount: Int) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return scopeIsAll || selectedLibraryCount >= 1
    }
}
