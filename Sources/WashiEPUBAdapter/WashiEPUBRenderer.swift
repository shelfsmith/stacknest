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
    /// G51: 窓が握るキー処理。native monitor で受けた NSEvent をそのまま渡す。
    var onKeyEvent: ((NSEvent) -> Bool)?
    /// G51: 本の端に達した通知（自動送りの停止判断）。
    var onReachBookEdge: ((Bool) -> Void)?
    /// G54-S3: census の完了・無効化の通知（窓の HUD を更新する）。
    var onPageCensusChange: (() -> Void)?
    private(set) var locator: EPUBLocatorValue?

    /// `makeReaderView` が open 済みの publication を置いておく場所。窓に載って実寸が
    /// 決まるまでは load() を呼ばない（G48-2 smoke: 白紙表紙の修正）。
    private var pendingLoad: (publication: EPUBPublication, locator: EPUBLocator?)?
    private var hasPerformedInitialLoad = false
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
        // G51（spec §3.1・Washi 前提）: キーは窓（EPUBReaderWindowController）が共有の割り当て表で扱う。
        // - native monitor（forwardsKeyEventsNatively）で WebView より先に NSEvent を受け、`onKeyEvent` へ渡す。
        // - JS 既定ナビ（矢印・Space・PageUp/Down・Home/End）は止める。表が唯一の権威になるため
        //   （表で Space を外せば EPUB でも Space は送らない）。
        // - 扱わなかったキーは `shouldConsumeKey → false` で responder チェーンへ返す（上流 1.16.3 が
        //   こちらの Issue #3 コメントを受けて追加した問い合わせ。1.16.2 までは false の分岐で握り潰していた）。
        reader.settings.forwardsKeyEventsNatively = true
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
        // G48-2-2: 開始 spine（復元位置か 0）についても、初回 load() の前に insets を決めておく
        // （表紙が画像ページなら最初から余白なしにするため）。
        updateInsets(for: pending.publication, spineIndex: pending.locator?.spineIndex ?? 0)
        let loadLine = "load: host=\(String(describing: self.hostView.bounds)) reader=\(String(describing: self.reader.bounds)) window=\(String(describing: self.hostView.window?.frame ?? .zero))"
        epubReaderLog.notice("\(loadLine, privacy: .public)")
        reader.load(publication: pending.publication, at: pending.locator)
    }

    var view: NSView { hostView }

    /// G54-S3c: 巻送りで窓から外すとき。コールバックと delegate を外し、`unload()` で WebView と
    /// 本の参照を放す。容れ物を親から外すと Washi は `viewDidMoveToWindow(nil)` で
    /// ネイティブキー監視（`forwardsKeyEventsNatively`）を外す — 残ると外した本がキーを横取りする。
    func tearDown() {
        onLocatorChange = nil
        onFontScaleChange = nil
        onKeyEvent = nil
        onReachBookEdge = nil
        onPageCensusChange = nil
        // まだ窓に載っていない（load 前）なら、以後 load させない。
        pendingLoad = nil
        hasPerformedInitialLoad = true
        hostView.host = nil
        reader.delegate = nil
        reader.unload()
        hostView.removeFromSuperview()
    }

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

    // MARK: G51 — 契約の追加分（Washi の公開 API へ委譲）

    func goToBookStart() { reader.goToBookStart() }
    func goToBookEnd() { reader.goToBookEnd() }
    /// Washi が RTL を見て goForward/goBackward に解く（G48-2 の native 経路と同じ）。
    func pageLeft() { reader.turnPageLeft() }
    func pageRight() { reader.turnPageRight() }

    var columnMode: EPUBColumnModeValue {
        get {
            switch reader.settings.columnMode {
            case .auto: return .auto
            case .single: return .single
            case .double: return .double
            }
        }
        set {
            let mapped: EPUBColumnMode
            switch newValue {
            case .auto: mapped = .auto
            case .single: mapped = .single
            case .double: mapped = .double
            }
            guard reader.settings.columnMode != mapped else { return }   // 同値再代入で再ページ割りを起こさない
            reader.settings.columnMode = mapped
        }
    }

    /// 全体ページ数（Washi の census）。計測完了まで nil。
    var globalPageCount: Int? { reader.censusTotalPages }
    /// 表示中のページの全体番号の範囲（0 始まり）。Washi の `currentGlobalPageRange` は 1 始まり。
    var currentGlobalPageRange: ClosedRange<Int>? {
        reader.currentGlobalPageRange.map { ($0.lowerBound - 1)...($0.upperBound - 1) }
    }
    func go(toGlobalPage page: Int) {
        guard let locator = reader.censusLocator(forGlobalPage: page) else { return }
        reader.go(to: locator)
    }
    var spineItemCount: Int? {
        reader.publication?.readingOrder.count ?? pendingLoad?.publication.readingOrder.count
    }

    func adjustFontScale(by delta: Double) { reader.adjustFontScale(by: delta) }
    /// 直接代入は Washi の `didChangeFontScale` を発火しないので、変化があれば自分で流す。
    func resetFontScale() {
        guard reader.settings.fontScale != 1.0 else { return }
        reader.settings.fontScale = 1.0
        onFontScaleChange?(1.0)
    }

    // MARK: G54-S3 — 演出・ノンブル・綴じ方向

    /// `reader.settings` への代入は再ページ割りを走らせうるので、同値なら代入しない。
    var pageTurnStyle: PageTurnStyleValue {
        get {
            switch reader.settings.pageTurnStyle {
            case .none: return .off
            case .fade: return .fade
            case .slide: return .slide
            }
        }
        set {
            let mapped: EPUBPageTurnStyle
            switch newValue {
            case .off: mapped = .none
            case .fade: mapped = .fade
            case .slide: mapped = .slide
            }
            guard reader.settings.pageTurnStyle != mapped else { return }
            reader.settings.pageTurnStyle = mapped
        }
    }

    var showsFolio: Bool {
        get { reader.settings.showsPageFurniture }
        set {
            guard reader.settings.showsPageFurniture != newValue else { return }
            reader.settings.showsPageFurniture = newValue
        }
    }

    var isRightToLeft: Bool { reader.isRTL }

    // MARK: EPUBReaderViewDelegate
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator, pageInItem: Int, pageCountInItem: Int) {
        let v = WashiLocatorMapping.toValue(locator)
        self.locator = v
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

    /// G51: 判定はしない。窓の `onKeyEvent` に渡し、その戻り値（消費したか）をそのまま返す。
    func readerView(_ view: EPUBReaderView, didReceiveNativeKey event: NSEvent) -> Bool {
        onKeyEvent?(event) ?? false
    }

    /// G51: コンテナ経路（WebView がフォーカスを持たない一瞬など）。判定は native 経路に一本化するので何もしない。
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}

    /// G51: 扱わなかったキーは responder チェーンへ返す（上流 1.16.3）。
    func readerView(_ view: EPUBReaderView, shouldConsumeKey event: EPUBKeyEvent) -> Bool { false }

    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {
        onReachBookEdge?(forward)
    }

    /// G54-S3: 全体ページ数の計測が完了・無効化された。
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        onPageCensusChange?()
    }
}
