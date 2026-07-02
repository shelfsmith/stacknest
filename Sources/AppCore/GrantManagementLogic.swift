// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// グラント管理 GUI の純ロジック（App の SwiftUI から呼ぶ・testable なので AppCore に置く）。
public enum GrantManagementLogic {
    /// GUI 一覧から除外する予約グラント ID。C-③b-2 で default-read/default-edit を一本化し
    /// 「共有トークン」として表示するため、除外は env-admin（ヘッドレス env 投入・GUI 管理外）のみ。
    public static let reservedIDs: Set<String> = ["env-admin"]

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
