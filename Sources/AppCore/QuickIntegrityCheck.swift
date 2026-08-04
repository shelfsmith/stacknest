// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// アーカイブ／フォルダを列挙した結果（I/O は呼び出し側が行う）。
public enum QuickProbe: Sendable, Equatable {
    /// 列挙できた。`truncated` は破損等で途中打ち切りになったことを示す。
    case enumerated(count: Int, truncated: Bool)
    /// 列挙そのものが失敗した（開けない等）。
    case failed(reason: String)
}

/// 簡易チェックの分類（spec §4.2）。**I/O を持たない純関数**にして全分岐をテスト可能にする。
public enum QuickIntegrityCheck {
    public struct Outcome: Sendable, Equatable {
        public let status: IntegrityStatus
        /// 書き戻してよい確定ページ数。破損時は nil（中途半端な値を確定させない）。
        public let pageCount: Int?
        public let reason: String?

        public init(status: IntegrityStatus, pageCount: Int?, reason: String? = nil) {
            self.status = status
            self.pageCount = pageCount
            self.reason = reason
        }
    }

    /// 列挙（I/O）が必要な種別か。image は開かずに 1 ページと確定できる。
    public static func needsProbe(category: BookCategory) -> Bool {
        switch category {
        case .archive, .folder: return true
        case .image, .video, .text: return false
        }
    }

    /// - Parameter fileSize: 呼び出し側が事前に stat したファイルサイズ（`exists` が true のときのみ
    ///   意味を持つ）。`.image` の分類にのみ使う ―― 0 バイトや stat 失敗（nil）の単独画像を
    ///   「開かずに確定できる 1 ページ」として誤って ok にしないため（Fix4: これをしないと
    ///   `pages` が 1 で書き込まれ、`pages IS NULL OR pages = 0` の次回候補から永久に外れる）。
    public static func classify(category: BookCategory, exists: Bool, probe: QuickProbe?,
                                fileSize: Int64? = nil) -> Outcome {
        guard exists else { return Outcome(status: .missing, pageCount: nil) }

        switch category {
        case .video, .text:
            // 動画・EPUB/テキスト/PDF は本フェーズの検査対象外。
            return Outcome(status: .unsupported, pageCount: nil)
        case .image:
            // 単独画像は列挙不要で 1 ページと確定できる ―― ただしサイズが確認できたときだけ。
            // 0 バイト（切り詰め/破損でよくある）や stat 失敗（nil）は「健康な1ページ」として
            // 記録してはいけない。archive/folder と違って image には probe による検証が無いため、
            // ここがこのファイルを検証する唯一の機会になる。
            guard let fileSize, fileSize > 0 else {
                return Outcome(status: .damaged, pageCount: nil,
                              reason: "image file size is zero or unknown")
            }
            return Outcome(status: .ok, pageCount: 1)
        case .archive, .folder:
            guard let probe else {
                // 呼び出し側が probe を怠った。バグを隠さないため明示的に damaged にする。
                return Outcome(status: .damaged, pageCount: nil, reason: "probe not performed")
            }
            switch probe {
            case .failed(let reason):
                return Outcome(status: .damaged, pageCount: nil, reason: reason)
            case .enumerated(let count, let truncated):
                if truncated {
                    // G26 の規則と同じ: 破損時は pages を書かない。
                    return Outcome(status: .damaged, pageCount: nil, reason: "enumeration truncated")
                }
                if count == 0 {
                    // 画像 0 枚は「確定した 0」。毎回再走査しないよう pages=0 を書いてよい。
                    return Outcome(status: .empty, pageCount: 0)
                }
                return Outcome(status: .ok, pageCount: count)
            }
        }
    }
}
