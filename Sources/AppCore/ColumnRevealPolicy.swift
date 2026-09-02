// SPDX-License-Identifier: MIT
import Foundation

/// G44: 列を表示にしたのに画面右端の外にあって見えない、を無くすための判断。
/// ローカル（BookTableCoordinator）とリモート（RemoteBookTableCoordinator）の `installColumns` が呼ぶ。
/// 列の表示切替は 3 経路ある（ヘッダの右クリック・メニューバー「テーブル列」・設定の同期）が、
/// どれも installColumns を通るので、ここ 1 箇所で全経路に効く。
public enum ColumnRevealPolicy {
    /// 列を作り直した後にスクロールすべき列のインデックス（`after` の中の位置）。
    /// - 新たに現れた識別子がちょうど 1 つのときだけ返す
    /// - 初回（`before` が空）・並べ替えだけ・OFF・複数同時は nil（何もしない）
    public static func newlyShownIndex(before: [String], after: [String]) -> Int? {
        guard !before.isEmpty else { return nil }
        let added = after.filter { !before.contains($0) }
        guard added.count == 1, let id = added.first else { return nil }
        return after.firstIndex(of: id)
    }
}
