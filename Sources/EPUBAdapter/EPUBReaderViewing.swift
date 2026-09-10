// SPDX-License-Identifier: MIT
import AppKit

/// G51: 段組み（見開き）の指定。Washi の `EPUBColumnMode` を写す値型（Washi の型は出さない）。
public enum EPUBColumnModeValue: Sendable, Equatable {
    case auto, single, double
}

/// 契約: 読書ビュー 1 枚。窓（App）はこれだけを知る。Washi の型は出ない。
@MainActor
public protocol EPUBReaderViewing: AnyObject {
    var view: NSView { get }
    /// いま表示している位置。読み込み前は nil。
    var locator: EPUBLocatorValue? { get }
    /// ページ送り・章移動・復元で位置が変わったら呼ばれる（保存に使う）。
    var onLocatorChange: ((EPUBLocatorValue) -> Void)? { get set }
    func go(to locator: EPUBLocatorValue)
    func goForward()
    func goBackward()
    func setTheme(_ theme: EPUBReaderThemeValue)
    /// フォント倍率（実装側の許容範囲へクランプして反映。Washi は 0.5...3.0）。
    var fontScale: Double { get set }
    /// フォント倍率がキー操作等で変わったら呼ばれる（永続化に使う）。
    var onFontScaleChange: ((Double) -> Void)? { get set }

    // MARK: G51 — キーは窓が握る

    /// 窓レベルで受けたキー。**true を返すと消費**（イベントは止まる）、false ならそのまま流れる。
    /// 実装はナビゲーションの JS 既定処理を止め、扱わなかったキーを responder チェーンへ返すこと。
    var onKeyEvent: ((NSEvent) -> Bool)? { get set }
    /// ページ送りで本の端に達した（`true` = 末尾、`false` = 先頭）。自動送りの停止判断に使う。
    var onReachBookEdge: ((Bool) -> Void)? { get set }

    // MARK: G51 — 移動

    /// 本の**最初のページ**へ（章の先頭ではない）。
    func goToBookStart()
    /// 本の**最後のページ**へ（章の末尾ではない）。
    func goToBookEnd()
    /// 左向きのページ送り。読む方向（縦組み RTL / 横組み LTR）は実装側が解決する。
    func pageLeft()
    /// 右向きのページ送り。
    func pageRight()
    /// 全体ページ数（本全体・現在のメトリクスでの実測）。計測が終わるまで nil。
    var globalPageCount: Int? { get }
    /// いま表示している最初のページの全体ページ番号（0 始まり）。計測が終わるまで nil。
    /// （G51 時点では窓側に利用者なし。進捗表示の第二弾で使う）
    var currentGlobalPage: Int? { get }
    /// 全体ページ番号（0 始まり）へ。計測が終わっていなければ何もしない。
    func go(toGlobalPage page: Int)
    /// spine（読み順）の項目数。読み込み前は nil。
    var spineItemCount: Int? { get }

    // MARK: G51 — 表示

    /// 段組み（見開き）。
    var columnMode: EPUBColumnModeValue { get set }
    /// フォント倍率を相対的に変える（許容範囲へクランプ。変化があれば `onFontScaleChange`）。
    func adjustFontScale(by delta: Double)
    /// フォント倍率を等倍（1.0）へ戻す（変化があれば `onFontScaleChange`）。
    func resetFontScale()
}
