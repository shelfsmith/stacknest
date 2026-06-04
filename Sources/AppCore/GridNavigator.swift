// SPDX-License-Identifier: MIT
import Foundation

/// Phase 2.5k: LazyVGrid 上の矢印 navigation で「現在 index + 方向 + 列数」から
/// 次の index を計算する純粋関数 + 空 list 用の `firstIndex`。
/// 端 (= 上端で ↑ / 下端で ↓ / 左端で ← / 右端で →) では nil を返し、
/// 半端最終行 (= 列数より短い行) では `min(targetIndex, total-1)` で clamp する。
public enum GridNavigator {
    public enum Direction: Sendable {
        case up, down, left, right
    }

    /// `current` index から `direction` 方向の隣接 cell の index を返す。
    /// 端で動けないときは nil。`total` ≤ 0 や `columns` ≤ 0 の病的入力でも nil。
    public static func nextIndex(
        current: Int,
        direction: Direction,
        total: Int,
        columns: Int
    ) -> Int? {
        guard total > 0, columns > 0 else { return nil }
        guard (0..<total).contains(current) else { return nil }

        let row = current / columns
        let col = current % columns

        switch direction {
        case .up:
            guard row > 0 else { return nil }
            return current - columns
        case .down:
            // targetIndex は同じ列の 1 行下、ただし total を超えるなら最終行の最右に clamp
            let target = current + columns
            if target < total { return target }
            // 半端最終行: 同列の次の行 cell が存在しない → 最終行の最右に降りる
            let lastIndex = total - 1
            let lastRow = lastIndex / columns
            // すでに最終行にいるなら nil (= 下に行けない)
            guard row < lastRow else { return nil }
            return lastIndex
        case .left:
            guard col > 0 else { return nil }
            return current - 1
        case .right:
            guard col < columns - 1 else { return nil }
            let target = current + 1
            // 同じ行内かつ total 範囲内
            return target < total ? target : nil
        }
    }

    /// 空でないとき先頭 (= 0) を返す。空なら nil。
    /// 「selection 無し + 矢印で先頭選択」の Finder 準拠挙動で使う。
    public static func firstIndex(total: Int) -> Int? {
        total > 0 ? 0 : nil
    }

    /// 末尾 (= total-1) を返す。空なら nil。⌘+↓ / End / 末尾ジャンプで使う。
    public static func lastIndex(total: Int) -> Int? {
        total > 0 ? total - 1 : nil
    }
}
