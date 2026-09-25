// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter

/// G54-S3e（spec §2.1-8・平木氏の判断 2026-09-25）: サーバの読書位置が分からないまま（manifest が取れずに）
/// 手元のファイルで開いた EPUB の保存を止める門。
///
/// 開いた直後に reader が報告する位置は先頭であって利用者の読書ではない。それをサーバへ送ると、
/// サーバ側の読書位置を先頭で上書きしてしまう。**最初に報告された位置と違う位置が来るまで**保存しない。
/// 一度開いたら閉じない（先頭へ戻ったのは利用者の操作）。
///
/// 位置の比較は spine と progress だけで行う。cfi・engine は、全画面化やリサイズの組み直しで
/// 同じ場所のまま変わりうる（`EPUBLocatorValue` の `==` は cfi まで比べるので使わない）。
public struct EPUBInitialPersistGate: Equatable, Sendable {
    /// 保存してよいか。止めない門（`holdUntilMoved == false`）は最初から true。
    public private(set) var allowsPersist: Bool
    private var first: EPUBLocatorValue?

    public init(holdUntilMoved: Bool) {
        allowsPersist = !holdUntilMoved
    }

    /// reader が報告した位置を見る（保存の前に毎回呼ぶ）。
    public mutating func observe(_ loc: EPUBLocatorValue) {
        guard !allowsPersist else { return }
        guard let first else {
            self.first = loc
            return
        }
        if loc.spine != first.spine || loc.progress != first.progress {
            allowsPersist = true
        }
    }
}
