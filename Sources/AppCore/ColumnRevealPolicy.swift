// SPDX-License-Identifier: MIT
import Foundation

/// G44: 列を表示にしたのに画面右端の外にあって見えない、を無くすための判断。
/// ローカル（BookTableCoordinator）とリモート（RemoteBookTableCoordinator）の両方がこれを呼ぶ。
/// 見た目の処理（scrollColumnToVisible）は呼び出し側。ここは「どの列へ」だけを決める。
public enum ColumnRevealPolicy {
    /// 表示切替の後にスクロールすべき列のインデックス。
    /// - OFF にした（`nowVisible == false`）なら nil（何もしない）
    /// - 列が見つからないなら nil
    /// `columnIdentifiers` は `installColumns` の**後**の `table.tableColumns` から取ること。
    public static func indexToReveal(toggled: BookColumn, nowVisible: Bool, columnIdentifiers: [String]) -> Int? {
        guard nowVisible else { return nil }
        return columnIdentifiers.firstIndex(of: toggled.rawValue)
    }
}
