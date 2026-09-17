// SPDX-License-Identifier: MIT
import Foundation

/// G54-S3: EPUB の窓の HUD に出す文字と進捗バーの割合。画像ビューアの
/// `ViewerModel.progressText` / `progressFraction` と同じ作法（1 始まり・見開きは「p–q / N」・割合は先頭ページ）。
/// 全体ページ数（Washi の census）の計測が終わるまでは「計測中…」と、章の位置からの概算を出す。
public struct EPUBProgressDisplay: Equatable, Sendable {
    public let text: String
    public let fraction: Double

    public static let measuringText = "計測中…"

    public init(text: String, fraction: Double) {
        self.text = text
        self.fraction = fraction
    }

    /// - Parameters:
    ///   - currentGlobalPageRange: 0 始まり（契約 `EPUBReaderViewing.currentGlobalPageRange` と同じ）。
    ///   - spineProgress: 章内の進み（0...1）。
    public static func make(globalPageCount: Int?, currentGlobalPageRange: ClosedRange<Int>?,
                            spineIndex: Int?, spineProgress: Double?, spineCount: Int?) -> EPUBProgressDisplay {
        if let count = globalPageCount, count > 0, let range = currentGlobalPageRange {
            // 計測値と実表示がずれる境界に備えて、全体ページ数の中へ丸める。
            let first = min(max(range.lowerBound, 0), count - 1) + 1
            let last = min(max(range.upperBound, 0), count - 1) + 1
            let text = first == last ? "\(first) / \(count)" : "\(first)–\(last) / \(count)"
            return EPUBProgressDisplay(text: text, fraction: Double(first) / Double(count))
        }
        guard let spineCount, spineCount > 0, let spineIndex else {
            return EPUBProgressDisplay(text: measuringText, fraction: 0)
        }
        let progress = min(1, max(0, spineProgress ?? 0))
        let raw = (Double(spineIndex) + progress) / Double(spineCount)
        return EPUBProgressDisplay(text: measuringText, fraction: min(1, max(0, raw)))
    }
}
