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
    /// G48-2 レビュー対応: 「どの WKWebView に注入済みか」を弱参照で追跡する。Washi は
    /// WebContent プロセスが落ちると `webViewWebContentProcessDidTerminate` →
    /// `reloadCurrentPublication()` → `rebuildWebView(for:)` で**新しい `WKWebViewConfiguration`
    /// の WebView を作り直す**（`.build/checkouts/Washi/Sources/Washi/Rendering/EPUBReaderView.swift`）。
    /// 古い config に足した `WKUserScript` は新しい WebView には引き継がれないため、Bool の
    /// 一度きりフラグでは再注入が止まり、表紙の比率崩れが無言で再発する。`reader.subviews` の
    /// 現在の WKWebView と本プロパティが指す WebView が食い違えば再注入し、更新する。
    private weak var injectedWebView: WKWebView?

    /// G48-2（2026-09-04 差し替え）: Washi の画像ページ CSS（`body svg { width:auto; height:auto }`＋
    /// `!important` の max-width/max-height。上流 Issue https://github.com/shunnag/Washi/issues/1）が
    /// svg を 0×0 に潰す問題への対処を、CSS＋DOM 属性書き換え（`meet`）の合わせ技から
    /// JS で寸法を直接与える方式に変更した。旧方式（`userCSS` の `height:100vh` 固定＋
    /// `preserveAspectRatio="none"` を `xMidYMid meet` に書き換え）は、箱の幅が Washi の
    /// `max-width`（ページ割りの再実行後にしか更新されない `!important`）で頭打ちになり、
    /// 窓のリサイズに対して画像が一拍遅れて追従し letterbox の余白も出ていた（実機で確認）。
    /// 本方式は viewport（`innerWidth`/`innerHeight` = Washi の `contentFrame()`）から
    /// 比率を保った px 寸法を計算し、`!important` の inline style で Washi の
    /// max-width/max-height を上書きするため、`resize` イベントに同期して即座に追従する。
    /// `WKUserScript`（`injectFitSvgImagePagesFixIfNeeded()`）と、`didMoveTo` からの
    /// 直接実行（`applyFitSvgImagePagesDirectly()`）の両方がこれを使う——
    /// WebKit は「すでに始まったナビゲーション」には後から足した `WKUserScript` を適用しない
    /// ため、`WKUserScript` だけでは初回表紙（＝ `performPendingLoad` が `reader.load()` の
    /// 後に注入していた場合）や WebContent プロセス復旧直後の最初の文書で効かないことがある。
    /// 直接実行はナビゲーション順序に依存せず「今表示中の文書」に確実に当たるので保険になる。
    /// `resize` リスナーは `window.__stacknestFitInstalled` で多重登録を防ぐ（冪等に何度呼んでもよい）。
    private static let fitSvgImagePagesScript = """
        (() => {
          const fit = () => {
            for (const svg of document.querySelectorAll('svg[viewBox]')) {
              // 画像 1 枚を包む svg だけ（テキスト混在の装飾 svg は触らない）
              if (!svg.querySelector('image') || svg.children.length !== 1) continue;
              const vb = svg.viewBox.baseVal;
              if (!vb || !vb.width || !vb.height) continue;
              svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
              const vw = innerWidth, vh = innerHeight, r = vb.width / vb.height;
              let w = vh * r, h = vh;
              if (w > vw) { w = vw; h = vw / r; }
              // Washi の max-width/max-height（!important）より優先させるため inline !important
              svg.style.setProperty('width', Math.floor(w) + 'px', 'important');
              svg.style.setProperty('height', Math.floor(h) + 'px', 'important');
              svg.style.setProperty('max-width', 'none', 'important');
              svg.style.setProperty('max-height', 'none', 'important');
            }
          };
          fit();
          if (!window.__stacknestFitInstalled) {
            window.__stacknestFitInstalled = true;
            addEventListener('resize', fit);
          }
        })();
        """

    override init() {
        hostView = WashiHostView(readerView: reader)
        super.init()
        hostView.host = self
        reader.delegate = self
        // G48-2（2026-09-04 差し替え）: 以前はここで `userCSS` に
        // `body svg[viewBox] { height: 100vh !important; width: auto !important; }` を注入していたが、
        // CSS だけでは Washi の `max-width`（ページ割りの再実行後にしか更新されない `!important`）の
        // 更新が遅れ、窓のリサイズに画像が一拍遅れて追従する問題があった（`fitSvgImagePagesScript` の
        // doc コメント参照）。寸法は JS（`fitSvgImagePagesScript`）が inline style で直接与えるため、
        // ここでの CSS 注入は不要（JS が走るまでの一瞬だけ Washi の `width:auto; height:auto` で
        // svg が 0×0 になりうるが、`.atDocumentEnd` で即座に修正されるため許容する）。
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
        // G48-2 Codex P2: WKUserScript は「これから始まるナビゲーション」にしか効かず、
        // すでに始まったナビゲーションには後から足しても効かない。`reader.load()` は Washi 内部で
        // 新しい WKWebView を作ってからナビゲーションを開始するため、通常ここでは
        // `reader.subviews` にまだ WebView は現れない（＝この呼び出しは実質何もしない）が、
        // 万一すでに WebView が存在していれば load() 前に注入できたほうがよいので試す。
        // 居なければ load() 直後にもう一度試み（従来どおりの経路）、
        // それでも表紙ナビゲーションには間に合わないことがあるため、
        // `readerView(_:didMoveTo:...)` からの直接実行（`applyFitSvgImagePagesDirectly()`）
        // が最終的な保険になる。
        injectFitSvgImagePagesFixIfNeeded()
        reader.load(publication: pending.publication, at: pending.locator)
        injectFitSvgImagePagesFixIfNeeded()
    }

    /// G48-2（2026-09-04 差し替え）: `fitSvgImagePagesScript`（doc コメント参照）を
    /// `WKUserScript` として注入する。CSS では画像 1 枚の svg ページの寸法・比率を
    /// Washi の `max-width`/`max-height`（!important）に勝てる形で強制できないため、
    /// JS が inline style で px 寸法を直接書き込む。Washi 上流へ報告する候補
    /// （body svg のデフォルト寸法算出、または画像ページ CSS 側での比率維持）。
    ///
    /// G48-2 レビュー対応: Washi は WebContent プロセスクラッシュからの復帰時に WKWebView を
    /// 作り直す（`injectedWebView` の doc コメント参照）ため、「1 回だけ」注入する Bool フラグでは
    /// 再構築後に無言で機能を失う。ここでは `reader.subviews` の現在の WKWebView が
    /// `injectedWebView` と**同一インスタンスかどうか**で要否を判定し、別物なら再注入して
    /// `injectedWebView` を更新する。`performPendingLoad` 直後（初回）に加え、
    /// `readerView(_:didMoveTo:pageInItem:pageCountInItem:)`（ページ遷移のたび）からも呼ぶ——
    /// 同一 WebView への呼び出しは早期 return するだけなので安価。WebView が作り直されても、
    /// 次にページへ到達した時点で復旧する。
    private func injectFitSvgImagePagesFixIfNeeded() {
        guard let wv = currentWebView(), wv !== injectedWebView else { return }
        injectedWebView = wv
        let script = WKUserScript(
            source: Self.fitSvgImagePagesScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        wv.configuration.userContentController.addUserScript(script)
        epubReaderLog.notice("fitSvgImagePages fix: user script injected")
    }

    /// G48-2 Codex P2: `WKUserScript` は次回以降のナビゲーション（次ページ・復旧後の再読込）向けの
    /// 保険に留まる。**今まさに表示されている文書**に対しては、`reader.subviews` から現在の
    /// `WKWebView` を取り出して JS を直接実行することでしか確実性を担保できない
    /// （すでに始まったナビゲーションには `WKUserScript` が効かないため）。
    /// 冪等（何度当てても副作用なし）なので、`didMoveTo` から毎回呼んでよい。
    /// 結果は無視し、失敗時のみ 1 行 `.notice` でログする。
    private func applyFitSvgImagePagesDirectly() {
        guard let wv = currentWebView() else { return }
        wv.evaluateJavaScript(Self.fitSvgImagePagesScript) { _, error in
            if let error {
                epubReaderLog.notice("fitSvgImagePages direct apply failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `reader.subviews` の中から現在の `WKWebView` を探す。Washi は WebView を直接の subview として
    /// 持つ（`injectFitSvgImagePagesFixIfNeeded` のコメント参照）。
    private func currentWebView() -> WKWebView? {
        for v in reader.subviews {
            if let wv = v as? WKWebView { return wv }
        }
        return nil
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
        // G48-2 レビュー対応: WebContent プロセスのクラッシュ復帰で WKWebView が作り直されている
        // ことがあるため、ページ遷移のたびに注入要否を確認する（同一 WebView なら早期 return）。
        injectFitSvgImagePagesFixIfNeeded()
        // G48-2 Codex P2: WKUserScript はすでに始まったナビゲーションに後から足しても効かないため、
        // 最初の項目（表紙）や WebContent プロセス復旧直後の最初の文書で無言のまま外れることがある。
        // 冪等なので、現在の文書に対して毎回直接 JS を当てて確実性を担保する。
        applyFitSvgImagePagesDirectly()
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
