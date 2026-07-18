// SPDX-License-Identifier: MIT
import Foundation
import Observation
import LibraryStore

/// 内蔵ビューアの表示オプション（方向・末挙動）。
public struct ViewerOptions: Sendable, Equatable {
    public var pageDirection: PageDirection
    public var endOfBookBehavior: EndOfBookBehavior

    public init(
        pageDirection: PageDirection = .defaultValue,
        endOfBookBehavior: EndOfBookBehavior = .defaultValue
    ) {
        self.pageDirection = pageDirection
        self.endOfBookBehavior = endOfBookBehavior
    }
}

/// `advance()` の結果。末挙動はコントローラが解釈する（モデルは DB を知らない）。
public enum AdvanceResult: Sendable, Equatable {
    case moved        // 通常移動した
    case endStop      // 末尾で停止した（クランプ）
    case endLoop      // 末尾→先頭にループした
    case endNextBook  // 末尾。コントローラに次巻ロードを要求する
}

/// 内蔵ビューアの純粋ナビゲーションロジック（UI 非依存・ユニットテスト対象）。
/// ページ番号は 0-based。ズーム/フィットは canvas 側 (NSScrollView) が source of truth。
@Observable
@MainActor
public final class ViewerModel {
    public let pageCount: Int
    public private(set) var currentPage: Int
    public var options: ViewerOptions
    /// 表示モード（single / spread）。本ごと状態から初期化される。
    public private(set) var displayMode: ViewerDisplayMode = .single
    /// 見開き時に表紙を独立表示するか。本ごと状態から初期化される。
    public private(set) var coverOffset: Bool = true
    /// 現在の見開き配列（spread モードで使用。single モードでは未使用）。
    public private(set) var spreads: [Spread] = []
    /// 現在表示中の見開き索引（spreads への索引）。
    public private(set) var currentSpreadIndex: Int = 0

    public init(pageCount: Int, options: ViewerOptions = ViewerOptions()) {
        self.pageCount = max(0, pageCount)
        self.currentPage = 0
        self.options = options
    }

    /// 「次」へ進む。
    /// - single モード: ページ単位。最終ページ未満なら +1（.moved）、最終ページなら末挙動。
    /// - spread モード: 見開き単位。最終見開き未満なら次見開きへ（currentPage はその先頭ページ）。
    ///   最終見開きなら `options.endOfBookBehavior` に従う。
    /// 戻り値は末挙動の判定結果（コントローラが次巻ロード等を実行する）。
    @discardableResult
    public func advance() -> AdvanceResult {
        guard pageCount > 0 else { return .endStop }
        if displayMode == .spread {
            if currentSpreadIndex < spreads.count - 1 {
                currentSpreadIndex += 1
                currentPage = spreads[currentSpreadIndex].pages.first ?? currentPage
                return .moved
            }
            return endOfBookOutcome()
        } else {
            if currentPage < pageCount - 1 {
                currentPage += 1
                return .moved
            }
            return endOfBookOutcome()
        }
    }

    /// 末尾に達したときの挙動を解決する。loop は先頭へ実際に移動する。
    private func endOfBookOutcome() -> AdvanceResult {
        switch options.endOfBookBehavior {
        case .stop:
            return .endStop
        case .loop:
            goFirst()
            return .endLoop
        case .nextBook:
            return .endNextBook
        }
    }

    /// 「前」へ戻る。
    /// - single モード: ページ単位、先頭でクランプ。
    /// - spread モード: 見開き単位、先頭でクランプ。currentPage はその見開きの先頭ページ。
    public func goBack() {
        guard pageCount > 0 else { return }
        if displayMode == .spread {
            if currentSpreadIndex > 0 {
                currentSpreadIndex -= 1
                currentPage = spreads[currentSpreadIndex].pages.first ?? currentPage
            }
        } else {
            if currentPage > 0 {
                currentPage -= 1
            }
        }
    }

    public func goFirst() {
        guard pageCount > 0 else { return }
        currentPage = 0
        if displayMode == .spread { currentSpreadIndex = 0 }
    }

    public func goLast() {
        guard pageCount > 0 else { return }
        if displayMode == .spread {
            // spread モードで見開き未設定なら現在状態を維持（no-op）。
            guard !spreads.isEmpty else { return }
            currentSpreadIndex = spreads.count - 1
            currentPage = spreads[currentSpreadIndex].pages.first ?? currentPage
        } else {
            currentPage = pageCount - 1
        }
    }

    /// 任意ページへジャンプ（範囲外はクランプ）。spread モードでは見開き索引も再アンカーする。
    public func goTo(page: Int) {
        guard pageCount > 0 else { return }
        currentPage = min(max(0, page), pageCount - 1)
        if displayMode == .spread { currentSpreadIndex = spreadIndex(containingPage: currentPage) }
    }

    /// 見開き配列を差し替える。現在ページを含む見開きへ currentSpreadIndex を再アンカーする。
    public func setSpreads(_ newSpreads: [Spread]) {
        spreads = newSpreads
        currentSpreadIndex = spreadIndex(containingPage: currentPage)
    }

    /// 表示モードを設定する。spread へ切り替えるときは呼び出し側が直後に setSpreads する。
    public func setDisplayMode(_ mode: ViewerDisplayMode) {
        displayMode = mode
    }

    /// 表紙独立フラグを設定する（見開き再構築は呼び出し側が行う）。
    public func setCoverOffset(_ value: Bool) {
        coverOffset = value
    }

    /// 指定 0-based ページを含む見開きの索引。見つからなければ 0。
    public func spreadIndex(containingPage page: Int) -> Int {
        if let idx = spreads.firstIndex(where: { $0.pages.contains(page) }) {
            return idx
        }
        return 0
    }

    /// 「現在 / 総数」表示文字列（1-based）。
    /// single: "p / N"、spread: "p–q / N"（q = 現在見開きの最後のページ、1-based）。
    public var progressText: String {
        guard pageCount > 0 else { return "0 / 0" }
        if displayMode == .spread, !spreads.isEmpty,
           currentSpreadIndex >= 0, currentSpreadIndex < spreads.count {
            let pages = spreads[currentSpreadIndex].pages
            let first = (pages.first ?? currentPage) + 1
            let last = (pages.last ?? currentPage) + 1
            if first == last {
                return "\(first) / \(pageCount)"
            }
            return "\(first)–\(last) / \(pageCount)"
        }
        return "\(currentPage + 1) / \(pageCount)"
    }

    /// 進捗バー用の 0.0...1.0 の割合（1-based / pageCount）。
    public var progressFraction: Double {
        guard pageCount > 0 else { return 0 }
        return Double(currentPage + 1) / Double(pageCount)
    }

    /// 最終ページか。spread モードでは最終見開きかどうかで判定する。
    public var isAtLastPage: Bool {
        if pageCount == 0 { return true }
        if displayMode == .spread {
            return spreads.isEmpty || currentSpreadIndex >= spreads.count - 1
        }
        return currentPage >= pageCount - 1
    }
}
