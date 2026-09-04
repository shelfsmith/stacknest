// SPDX-License-Identifier: MIT
import Foundation

/// EPUB の各ページの見開き指定（itemref の page-spread-*）。今回は保持のみ（見開きの組み方は既存の規則）。
public enum EPUBPageSpread: String, Sendable, Equatable { case left, right, center, none }

/// G48-2b: 全ページが画像の EPUB を「開いた状態」で表す handle。実装が EPUB を 1 回だけ開いて抱える。
/// `BookContent` が Sendable なので handle も Sendable。Washi の型は出ない。
public protocol EPUBImageBookReading: Sendable {
    var pageCount: Int { get }
    var readingDirection: EPUBReadingDirection { get }
    var spreads: [EPUBPageSpread] { get }
    /// ページ index（0 始まり）の画像バイト列（EPUB に入っている形式そのまま: JPEG/PNG/WebP 等）。
    func imageData(at index: Int) async throws -> Data
}
