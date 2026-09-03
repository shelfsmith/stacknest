// SPDX-License-Identifier: MIT
import AppKit

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
}
