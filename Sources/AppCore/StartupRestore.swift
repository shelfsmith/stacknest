// SPDX-License-Identifier: MIT
import Foundation

/// `.lastOpened` 起動で復元すべきライブラリ URL を解決する純ロジック（C-④a）。
public enum StartupRestore {
    /// - openSet: 前回終了時に開いていた庫の集合（nil = 未書込＝アップグレード直後/新規）。
    /// - recencyFirst: 最近開いた先頭 1 庫（未書込フォールバック＋フォーカス用）。
    /// - exists: bundle が現存し妥当か。
    /// - Returns: 開くべき URL 列（存在するもののみ・recencyFirst を末尾へ寄せてフォーカス対象に）。
    public static func librariesToRestore(openSet: [URL]?, recencyFirst: URL?, exists: (URL) -> Bool) -> [URL] {
        let base: [URL]
        if let openSet {
            base = openSet.filter(exists)
        } else if let recencyFirst, exists(recencyFirst) {
            base = [recencyFirst]
        } else {
            base = []
        }
        guard let recencyFirst, base.contains(recencyFirst) else { return base }
        return base.filter { $0 != recencyFirst } + [recencyFirst]
    }
}
