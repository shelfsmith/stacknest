// SPDX-License-Identifier: MIT
import AppKit
import EPUBAdapter
import WashiCore
import Washi   // ← 表示層。リポジトリでここだけ
import os

/// 初回 load・読み込み失敗を最小限だけ記録する。
/// 個人情報（パス・題名）は出さない — サイズ・spine index・エラー型のみ。
private let epubReaderLog = Logger(subsystem: "app.shelfsmith.stacknest", category: "EPUBReader")

public struct WashiEPUBRenderer: EPUBRendering {
    public init() {}

    @MainActor
    public func makeReaderView(url: URL, at locator: EPUBLocatorValue?) async throws -> any EPUBReaderViewing {
        let pub: EPUBPublication
        do { pub = try await EPUBPublication.open(url: url, readStrategy: .alwaysCopy) }
        catch { throw EPUBAdapterError.cannotOpen("\(type(of: error)): \(error)") }
        let host = WashiReaderHost()
        // G48-2 smoke fix: ここでは load() しない。Washi は load() 時点の `bounds.size` で
        // 内部 WebView のフレームを決めるため、窓に載る前（frame .zero）に呼ぶと先頭項目
        // （表紙）が 0×0 のまま描かれ、以降の再ページ割りでも白紙のまま残る
        // （EPUBReaderView.load()/contentFrame() は `bounds.width/height` を直接使う）。
        // 実際の load は host.hostView（WashiHostView）が窓に載って実寸を得たときに 1 回だけ行う。
        host.scheduleLoad(publication: pub, locator: locator.map(WashiLocatorMapping.toWashi))
        return host
    }
}

/// `EPUBReaderView` を直接窓に載せず、容れ物の `NSView`（`WashiHostView`）に包んで返す。
/// 容れ物が「窓に載り、かつ実寸（0×0 でない）になった」瞬間を検知して初回 load() を行う。
@MainActor
final class WashiHostView: NSView {
    let readerView: EPUBReaderView
    weak var host: WashiReaderHost?

    init(readerView: EPUBReaderView) {
        self.readerView = readerView
        super.init(frame: .zero)
        readerView.autoresizingMask = [.width, .height]
        readerView.frame = bounds
        addSubview(readerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncReaderFrame()
        attemptPendingLoad()
    }

    override func layout() {
        super.layout()
        syncReaderFrame()
        attemptPendingLoad()
    }

    /// `readerView` を `autoresizingMask` 任せにしない。親（`self`）が frame `.zero` の間に
    /// 追加された subview は、AppKit の autoresizing 比例計算（旧サイズに対する新旧比）が
    /// 0 除算になり、親が実寸になっても 0×0 のまま取り残されることがある（既知の落とし穴）。
    /// その状態で Washi が内部 WebView を作ると load() 時点のフレームが 0×0 になり、
    /// 表紙が白紙のまま残る。autoresizingMask は保持しつつ、レイアウトの都度ここで
    /// `frame = bounds` を明示的に上書きして確実に追従させる。
    private func syncReaderFrame() {
        guard readerView.frame != bounds else { return }
        readerView.frame = bounds
    }

    /// `window != nil` かつ実寸が付いた最初の機会に、ホストへ 1 回だけ load() を促す。
    /// 二重実行の防止は `WashiReaderHost.performPendingLoad()` 側（`hasPerformedInitialLoad`）が担う。
    private func attemptPendingLoad() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        host?.performPendingLoad()
    }
}

/// `EPUBReaderView` を契約に合わせて包む。delegate の位置変化を `onLocatorChange` に流す。
@MainActor
final class WashiReaderHost: NSObject, EPUBReaderViewing, EPUBReaderViewDelegate {
    let reader = EPUBReaderView(frame: .zero)
    private let hostView: WashiHostView
    var onLocatorChange: ((EPUBLocatorValue) -> Void)?
    var onFontScaleChange: ((Double) -> Void)?
    private(set) var locator: EPUBLocatorValue?

    /// `makeReaderView` が open 済みの publication を置いておく場所。窓に載って実寸が
    /// 決まるまでは load() を呼ばない（G48-2 smoke: 白紙表紙の修正）。
    private var pendingLoad: (publication: EPUBPublication, locator: EPUBLocator?)?
    private var hasPerformedInitialLoad = false
    /// Home/End（現在の spine 項目の先頭/末尾）用に `didMoveTo` で更新する。
    private var currentSpineIndex = 0
    /// G48-2-2（2026-09-04・ユーザー指示）: 画像 1 枚のページでは insets（本文用の余白）を 0 にする。
    /// 固定レイアウト経路（itemref が pre-paginated）は insets を使わず枠いっぱいに描くため、
    /// リフロー経路の画像ページも同じ見え方（枠いっぱい）に揃える。`init` 時点の
    /// `reader.settings.insets`（本文用の既定値）を保持しておき、テキストページに戻すときに使う。
    /// G48-4: 画像ページの描画（比率・リサイズ追従）は Washi 1.14.1 以降が担う（上流 Issue #1）。
    /// ここは insets の切替だけ。
    private let textInsets: EPUBReaderInsets

    override init() {
        hostView = WashiHostView(readerView: reader)
        textInsets = reader.settings.insets
        super.init()
        hostView.host = self
        reader.delegate = self
        // G48-2 最終レビュー C: 窓を開いた直後は JS 側の `didReceiveKey` 経路が効かないことがある
        // （WKWebView がファーストレスポンダを持っていないと発火しない）。Washi README 推奨どおり
        // ネイティブ NSEvent 経路（`didReceiveNativeKey`）に切り替え、`readerView(_:didReceiveNativeKey:)`
        // で矢印・スペース・PageUp/Down をページ送りに直結する。契約 `EPUBReaderViewing` は
        // goForward/goBackward しか持たないため、このキー処理は Washi 実装（本ファイル）の中だけで閉じる。
        reader.settings.forwardsKeyEventsNatively = true
        // G48-4 smoke（2026-09-06）クラッシュ対策: Washi 1.16.0 の `EPUBReaderView.keyDown`（cooViewer-oxr.80）は
        // `handlesKeyboardNavigation == true` のとき受け取ったキーを自分の WebView へ転送する。WebView が
        // 扱わないキー（⌘なしの `+`・`-`・Esc 等）は `super` → nextResponder（= コンテナ自身）へ戻るため
        // 往復して無限再帰し、スタックオーバーフローで落ちる（クラッシュログ: `EPUBReaderView.keyDown` ↔
        // `_web_superKeyDown` の反復）。ナビゲーションは上の native monitor（`didReceiveNativeKey`）で
        // 完結させているので、Washi 側の既定キー処理と転送を切る（false にするとコンテナは delegate の
        // `didReceiveKey` へ流すだけで WebView へ戻さない）。JS が担っていた ↑↓/Home/End も native 側に持つ。
        reader.settings.handlesKeyboardNavigation = false
    }

    /// `WashiEPUBRenderer.makeReaderView` から呼ぶ。実行はまだしない。
    func scheduleLoad(publication: EPUBPublication, locator: EPUBLocator?) {
        pendingLoad = (publication, locator)
    }

    /// G48-2-2: spine index が「画像 1 枚のページ」かどうかを判定する。WashiCore の
    /// `EPUBPublication.fixedLayoutInfo(forSpineIndex:)` は固定レイアウト項目に限らず、
    /// リフロー項目でも「img/svg 単体で構成されたページ」を `simpleImagePath` で検出できる
    /// （doc コメント: "Also returns viewport-less info for the spine items of a reflowable
    /// book"）。固定レイアウト経路（pre-paginated）は元々 insets を使わず枠いっぱいに描くので、
    /// ここでの判定はリフロー経路の画像ページを拾うことが主目的になる。取得に失敗したら
    /// false（テキスト扱い＝insets を残す）にフォールバックする。
    private func isImagePage(of publication: EPUBPublication, spineIndex: Int) -> Bool {
        guard publication.readingOrder.indices.contains(spineIndex) else { return false }
        return (try? publication.fixedLayoutInfo(forSpineIndex: spineIndex))?.simpleImagePath != nil
    }

    /// G48-2-2: 画像ページなら insets を 0、それ以外は `textInsets`（本文用の既定値）に戻す。
    /// `reader.settings.insets` の didSet は再ページ割りを走らせるため、**値が現在と異なる
    /// ときだけ**代入する（同じ値への再代入で無駄な再ページ割りを起こさない）。
    private func updateInsets(for publication: EPUBPublication, spineIndex: Int) {
        let wanted = isImagePage(of: publication, spineIndex: spineIndex)
            ? EPUBReaderInsets(top: 0, left: 0, bottom: 0, right: 0)
            : textInsets
        guard reader.settings.insets != wanted else { return }
        reader.settings.insets = wanted
    }

    /// `WashiHostView` からのみ呼ばれる。`hasPerformedInitialLoad` で二重実行を防ぐ。
    func performPendingLoad() {
        guard !hasPerformedInitialLoad, let pending = pendingLoad else { return }
        hasPerformedInitialLoad = true
        pendingLoad = nil
        currentSpineIndex = pending.locator?.spineIndex ?? 0   // 最初の didMoveTo が来るまでの Home/End 用
        // G48-2-2: 開始 spine（復元位置か 0）についても、初回 load() の前に insets を決めておく
        // （表紙が画像ページなら最初から余白なしにするため）。
        updateInsets(for: pending.publication, spineIndex: pending.locator?.spineIndex ?? 0)
        let loadLine = "load: host=\(String(describing: self.hostView.bounds)) reader=\(String(describing: self.reader.bounds)) window=\(String(describing: self.hostView.window?.frame ?? .zero))"
        epubReaderLog.notice("\(loadLine, privacy: .public)")
        reader.load(publication: pending.publication, at: pending.locator)
    }

    var view: NSView { hostView }

    func go(to locator: EPUBLocatorValue) {
        let mapped = WashiLocatorMapping.toWashi(locator)
        guard hasPerformedInitialLoad else {
            // 窓に載る前（load() 未実行）の呼び出し: 落とさず、pending の開始位置を
            // 差し替えるだけにする（Washi 自身の go(to:) も publication == nil の間は
            // 安全に no-op だが、こちらは狙った位置から開けるようにする）。
            if var pending = pendingLoad {
                pending.locator = mapped
                pendingLoad = pending
            }
            return
        }
        reader.go(to: mapped)
    }
    func goForward() { reader.goForward() }
    func goBackward() { reader.goBackward() }
    func setTheme(_ theme: EPUBReaderThemeValue) {
        switch theme {
        case .system: reader.settings.theme = .system
        case .light:  reader.settings.theme = .light
        case .dark:   reader.settings.theme = .dark
        }
    }

    /// フォント倍率。Washi 側の許容範囲（`EPUBReaderView.fontScaleRange` = 0.5...3.0）へクランプする。
    /// 直接代入は delegate の `didChangeFontScale` を発火させない（Washi 自身がピンチ／
    /// `adjustFontScale(by:)` 経由でしか呼ばない）ので、App 層が復元値をここへ書き戻しても
    /// `onFontScaleChange` への往復（＝無駄な再保存）は起きない。
    var fontScale: Double {
        get { reader.settings.fontScale }
        set {
            let range = EPUBReaderView.fontScaleRange
            reader.settings.fontScale = min(range.upperBound, max(range.lowerBound, newValue))
        }
    }

    // MARK: EPUBReaderViewDelegate
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator, pageInItem: Int, pageCountInItem: Int) {
        let v = WashiLocatorMapping.toValue(locator)
        self.locator = v
        currentSpineIndex = locator.spineIndex
        onLocatorChange?(v)
        // G48-2-2: 現在の spine が画像ページかどうかで insets を切り替える（doc コメント:
        // `updateInsets(for:spineIndex:)`）。`reader.publication` は load() 後は必ず non-nil。
        if let publication = reader.publication {
            updateInsets(for: publication, spineIndex: locator.spineIndex)
        }
    }

    /// 読み込み失敗をログする（白紙表紙の追跡）。パス・題名は出さず、エラー型のみ。
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        let failLine = "fail: \(String(describing: type(of: error)))"
        epubReaderLog.error("\(failLine, privacy: .public)")
    }

    /// フォント倍率がピンチ／`adjustFontScale(by:)`（キー操作含む）で変わったら、
    /// 永続化のため `onFontScaleChange` に流す。
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {
        onFontScaleChange?(scale)
    }

    /// G48-2 最終レビュー C: 矢印は `turnPageLeft()`/`turnPageRight()`（RTL は Washi 内部で解決）、
    /// スペース／Page Down は `goForward()`、Shift+スペース／Page Up は `goBackward()` に繋ぐ。
    /// G48-2 smoke fix: ⌘+/⌘= でフォント拡大、⌘- で縮小、⌘0 で等倍へリセット
    /// （`EPUBReaderSettings.fontScale`、範囲は `EPUBReaderView.fontScaleRange`）。
    /// 未対応キーは false を返し JS 経路・既定動作へフォールスルーさせる。
    func readerView(_ view: EPUBReaderView, didReceiveNativeKey event: NSEvent) -> Bool {
        switch Self.navigationKey(for: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
        case .left: view.turnPageLeft(); return true
        case .right: view.turnPageRight(); return true
        case .forward: view.goForward(); return true
        case .backward: view.goBackward(); return true
        case .home, .end:
            // JS 既定と同じ: 固定レイアウト／画像 1 枚の項目（1 ページ）では progression 0/1 が同じページに
            // なって何も起きないので、項目境界を越える goBackward/goForward に倒す（レビュー指摘）。
            let forward = Self.navigationKey(for: event.keyCode, shift: false) == .end
            if let publication = view.publication, isSinglePageItem(of: publication, spineIndex: currentSpineIndex) {
                if forward { view.goForward() } else { view.goBackward() }
            } else {
                view.go(to: EPUBLocator(spineIndex: currentSpineIndex, progression: forward ? 1 : 0, idref: nil))
            }
            return true
        case nil: break
        }
        guard let delta = Self.fontScaleDelta(for: event) else { return false }
        if delta == 0 {
            guard view.settings.fontScale != 1.0 else { return true }
            view.settings.fontScale = 1.0
            onFontScaleChange?(1.0)  // 直接代入は didChangeFontScale を発火しないので手動で流す
        } else {
            view.adjustFontScale(by: delta)
        }
        return true
    }

    /// Home/End の分岐用: 固定レイアウト（itemref の実効 layout が pre-paginated）か画像 1 枚のページ（`simpleImagePath`）は
    /// 1 ページの項目。`fixedLayoutInfo.viewportSize` は package の `rendition:viewport` がリフロー章にも当たるので
    /// 指標にしない（レビュー指摘）。
    private func isSinglePageItem(of publication: EPUBPublication, spineIndex: Int) -> Bool {
        guard publication.readingOrder.indices.contains(spineIndex) else { return false }
        if publication.package.effectiveLayout(for: publication.readingOrder[spineIndex].itemRef) == .prePaginated { return true }
        return isImagePage(of: publication, spineIndex: spineIndex)
    }

    /// ⌘+/⌘-/⌘0 の判定を **文字**（`charactersIgnoringModifiers`／`characters`）で行う。
    /// keyCode は物理配列依存で、JIS では keyCode 24 が `^`、`+` は Shift+`;`（keyCode 41）に
    /// 割り当てられており US 前提の keyCode 判定（24/27/29）が JIS で成立しない（G48-2 実機不具合）。
    /// ⌘ 押下時の文字は次の 2 系統を両方見る:
    /// - `charactersIgnoringModifiers`: Shift を無視した「素の物理キー」の文字（US "=" キーはそのまま "="／
    ///   JIS ";" キーはそのまま ";"）
    /// - `characters`: Shift を反映した文字（JIS の ⌘Shift+; は ";" キーに Shift が乗るため "+" になる）
    /// テンキーの `+`/`-` も同じ文字コードなので自然に一致する。
    /// - Returns: `+0.1`（拡大）／`-0.1`（縮小）／`0`（⌘0＝等倍へリセット）／`nil`（対象外・⌘ 未押下）。
    nonisolated static func fontScaleDelta(for event: NSEvent) -> Double? {
        guard event.modifierFlags.contains(.command) else { return nil }
        let candidates = [event.charactersIgnoringModifiers, event.characters].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        if candidates.contains("0") { return 0 }
        if candidates.contains(where: { $0 == "+" || $0 == "=" || $0 == ";" }) { return 0.1 }
        if candidates.contains(where: { $0 == "-" || $0 == "_" }) { return -0.1 }
        return nil
    }

    // macOS 仮想キーコード(`Carbon.HIToolbox` の定数と同値。依存を増やさないためリテラルで持つ)。
    // 矢印・スペース・PageUp/Down・Home/End は物理配列に依存しない特殊キーなので keyCode のまま判定する。
    private static let keyCodeLeftArrow: UInt16 = 123
    private static let keyCodeRightArrow: UInt16 = 124
    private static let keyCodeDownArrow: UInt16 = 125
    private static let keyCodeUpArrow: UInt16 = 126
    private static let keyCodePageUp: UInt16 = 116
    private static let keyCodePageDown: UInt16 = 121
    private static let keyCodeSpace: UInt16 = 49
    private static let keyCodeHome: UInt16 = 115
    private static let keyCodeEnd: UInt16 = 119

    /// ナビゲーションキーの写像（純粋・テスト可）。Washi の JS 既定（矢印・Space・PageUp/Down・Home/End）と同じ割り当て。
    /// 左右は「見た目の方向」（`turnPageLeft/Right` が綴じ方向を解決）、↑↓/PageUp/Down/Space は論理方向、
    /// Home/End は現在の spine 項目の先頭/末尾。
    enum NavigationKey: Equatable { case left, right, forward, backward, home, end }
    nonisolated static func navigationKey(for keyCode: UInt16, shift: Bool) -> NavigationKey? {
        switch keyCode {
        case keyCodeLeftArrow: return .left
        case keyCodeRightArrow: return .right
        case keyCodeSpace: return shift ? .backward : .forward
        case keyCodePageDown, keyCodeDownArrow: return .forward
        case keyCodePageUp, keyCodeUpArrow: return .backward
        case keyCodeHome: return .home
        case keyCodeEnd: return .end
        default: return nil
        }
    }
}
