// SPDX-License-Identifier: MIT
import AppKit
import EPUBAdapter
import WashiCore
import Washi   // ← 表示層。リポジトリでここだけ
import WebKit
import os

/// 初回 load・読み込み失敗を最小限だけ記録する。個人情報（パス・題名）は出さない
/// — サイズ・spine index・エラー型のみ。
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
    /// G48-2 最終手当て: `injectPreserveAspectRatioFix()` の二重登録防止。
    private var hasInjectedPreserveAspectRatioFix = false

    override init() {
        hostView = WashiHostView(readerView: reader)
        super.init()
        hostView.host = self
        reader.delegate = self
        // G48-2 smoke fix: Washi の画像ページ CSS（body svg { width:auto; height:auto } と
        // `!important` の max-width/max-height）が、`<div class="main"><svg width="100%"
        // height="100%">` を包む日本語 EPUB の全面画像ページで svg を 0×0 に潰す（DOM 実測で確認済み。
        // 原因は ReaderScripts.swift の画像ページ CSS）。userCSS は Washi の CSS の後に注入されるため、
        // ここで viewBox を持つ svg にビューポート単位の寸法を明示的に与え、Washi 側の
        // max-width/max-height（!important・ページ寸）に収めさせる。ラッパーは flex 中央寄せの
        // ままなので、余白は中央に出る。Washi 上流へ報告する候補（body svg のデフォルト寸法算出）。
        // <image> の寸法は属性に任せる。CSS で width/height 両方を 100% 指定すると、Calibre/Kindle
        // 生成の表紙 svg（`preserveAspectRatio="none"` = 箱に合わせて引き伸ばす指定）が画面比に
        // 引き伸ばされる（2026-09-04 実機で確認。出版社製ページは既定の meet なので無事）。
        // 高さだけ !important で固定し幅は auto にすると、置換要素と同じ扱いで width が viewBox の
        // 縦横比から算出される。preserveAspectRatio="none" でも箱の比率＝画像の比率になるため崩れない。
        // Washi の max-width（!important・ページ幅）は残るので、横長画像は幅で頭打ちになる
        // （none の横長表紙だけ僅かに縦に潰れうる。稀なので許容）。
        reader.settings.userCSS = """
            body svg[viewBox] { height: 100vh !important; width: auto !important; }
            """
        // G48-2 最終レビュー C: 窓を開いた直後は JS 側の `didReceiveKey` 経路が効かないことがある
        // （WKWebView がファーストレスポンダを持っていないと発火しない）。Washi README 推奨どおり
        // ネイティブ NSEvent 経路（`didReceiveNativeKey`）に切り替え、`readerView(_:didReceiveNativeKey:)`
        // で矢印・スペース・PageUp/Down をページ送りに直結する。契約 `EPUBReaderViewing` は
        // goForward/goBackward しか持たないため、このキー処理は Washi 実装（本ファイル）の中だけで閉じる。
        reader.settings.forwardsKeyEventsNatively = true
    }

    /// `WashiEPUBRenderer.makeReaderView` から呼ぶ。実行はまだしない。
    func scheduleLoad(publication: EPUBPublication, locator: EPUBLocator?) {
        pendingLoad = (publication, locator)
    }

    /// `WashiHostView` からのみ呼ばれる。`hasPerformedInitialLoad` で二重実行を防ぐ。
    func performPendingLoad() {
        guard !hasPerformedInitialLoad, let pending = pendingLoad else { return }
        hasPerformedInitialLoad = true
        pendingLoad = nil
        let loadLine = "load: host=\(String(describing: self.hostView.bounds)) reader=\(String(describing: self.reader.bounds)) window=\(String(describing: self.hostView.window?.frame ?? .zero))"
        epubReaderLog.notice("\(loadLine, privacy: .public)")
        reader.load(publication: pending.publication, at: pending.locator)
        injectPreserveAspectRatioFix()
    }

    /// G48-2 最終手当て: `preserveAspectRatio="none"` の表紙 svg は CSS では比率維持を強制できない
    /// （箱に合わせて引き伸ばす指定そのものを CSS が上書きできないため）。窓を狭めると Washi の
    /// max-width（!important・ページ幅）で幅だけ頭打ちになり、`100vh` 固定の高さと組み合わさって
    /// 縦に伸びる。DOM 属性を `xMidYMid meet` に書き換えて比率維持へ倒す。Washi 上流へ報告する候補
    /// （表紙 svg の `preserveAspectRatio="none"` 尊重、または画像ページ CSS 側での比率維持）。
    /// `reader.load()` 直後に 1 回だけ呼ぶ（Washi は load() のたびに WKWebView を作り直すため）。
    /// 同じ本の spine 遷移は同じ WebView 内のナビゲーションなので、登録したユーザースクリプトは
    /// 各ページで走る。
    private func injectPreserveAspectRatioFix() {
        guard !hasInjectedPreserveAspectRatioFix else { return }
        var webView: WKWebView?
        for v in reader.subviews {
            if let wv = v as? WKWebView {
                webView = wv
                break
            }
        }
        guard let wv = webView else { return }
        hasInjectedPreserveAspectRatioFix = true
        let js = """
            (() => {
              for (const svg of document.querySelectorAll('svg[preserveAspectRatio="none"]')) {
                // 画像 1 枚を包む svg だけ（テキスト混在の装飾 svg は触らない）
                if (svg.querySelector('image') && svg.children.length === 1) {
                  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
                }
              }
            })();
            """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        wv.configuration.userContentController.addUserScript(script)
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
        onLocatorChange?(v)
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
        switch event.keyCode {
        case Self.keyCodeLeftArrow:
            view.turnPageLeft(); return true
        case Self.keyCodeRightArrow:
            view.turnPageRight(); return true
        case Self.keyCodeSpace:
            if event.modifierFlags.contains(.shift) { view.goBackward() } else { view.goForward() }
            return true
        case Self.keyCodePageDown:
            view.goForward(); return true
        case Self.keyCodePageUp:
            view.goBackward(); return true
        default:
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
    // 矢印・スペース・PageUp/Down は物理配列に依存しない特殊キーなので keyCode のまま判定する。
    private static let keyCodeLeftArrow: UInt16 = 123
    private static let keyCodeRightArrow: UInt16 = 124
    private static let keyCodePageUp: UInt16 = 116
    private static let keyCodePageDown: UInt16 = 121
    private static let keyCodeSpace: UInt16 = 49
}
