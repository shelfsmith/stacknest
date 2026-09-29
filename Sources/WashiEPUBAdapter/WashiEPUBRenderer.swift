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
        host?.hostViewDidChangeWindow()
        syncReaderFrame()
        attemptPendingLoad()
    }

    /// G56: 大きさの変化をホストへ知らせる（開いた直後の全画面化で文を保つ）。
    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard newSize != oldSize,
              oldSize.width > 0, oldSize.height > 0,
              newSize.width > 0, newSize.height > 0 else { return }
        host?.hostViewDidResize()
    }

    override func layout() {
        super.layout()
        syncReaderFrame()
        attemptPendingLoad()
    }

    /// G56-S3: システムの外観（ライト／ダーク）が変わったら、`theme == .system` のパレットを入れ替える。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        host?.refreshAppearanceForSystemChange()
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

    // MARK: G56-S2 — 文の位置の補完

    /// 復元直後の保護の鍵（着地の報告の spine と progress）。
    struct LandingKey: Equatable { let spine: Int; let progress: Double }
    /// アンカー付きで復元した直後の保護。利用者が動くまで、報告に復元のアンカーを付けたままにする
    /// （開いてすぐ閉じても、保存済みのアンカーが進行率だけに格下げされない）。
    struct RestoredAnchor { let anchor: EPUBLocator; var landing: LandingKey? }

    /// 位置の報告ごとに進める世代。非同期の補完が、その間に来た次の報告を追い越さないようにする。
    private var reportGeneration = 0
    private var restoredAnchor: RestoredAnchor?
    /// 最後に `onLocatorChange` へ出した位置（Washi の型）。Task 9 の「設定変更で同じ文へ戻る」が使う。
    private(set) var lastPublished: EPUBLocator?
    /// 現在位置をアンカー付きで取る（JS 1 往復）。テストで差し替える。
    lazy var fetchAnchoredLocator: @MainActor () async -> EPUBLocator = { [weak self] in
        guard let self else { return EPUBLocator(spineIndex: 0) }
        return await self.reader.currentLocatorWithTextAnchor()
    }

    private func publish(_ l: EPUBLocator) {
        lastPublished = l
        let v = WashiLocatorMapping.toValue(l)
        locator = v
        onLocatorChange?(v)
    }

    private func armRestoredAnchor(_ l: EPUBLocator?) {
        guard let l, l.textOffset != nil else { restoredAnchor = nil; return }
        restoredAnchor = RestoredAnchor(anchor: l, landing: nil)
    }

    // MARK: G56-S2 — 設定変更の後に同じ文へ戻る

    /// 戻り先を控えてから、次の位置の報告まで待つ上限（再ページ割りが報告を出さなかったときの安全弁）。
    static let relandDeadline: TimeInterval = 2.0
    private var relandTarget: (anchor: EPUBLocator, deadline: Date)?
    /// テストで差し替える。既定は Washi へそのまま渡す。
    lazy var navigateReader: @MainActor (EPUBLocator) -> Void = { [weak self] in self?.reader.go(to: $0) }
    var now: @MainActor () -> Date = { Date() }

    /// 組版が変わる変更の直前に呼ぶ。最後に出した位置にアンカーがあれば、それを戻り先に控える。
    /// 復元の保護が張られている間（まだ動いていない）は、保護のアンカーを優先する。続けて変えたとき、
    /// 1 回目の再ページ割りの報告は保護の鍵が外れてアンカー無しで出るため、lastPublished には文が無い。
    func captureRelandTarget() {
        guard hasPerformedInitialLoad, relandTarget == nil,
              let anchor = restoredAnchor?.anchor ?? lastPublished,
              anchor.textOffset != nil else { return }
        relandTarget = (anchor, now().addingTimeInterval(Self.relandDeadline))
    }

    /// `WashiHostView` の大きさが変わった（0 と同じ大きさは除く）。復元の保護が張られている間
    /// （開いた直後の全画面化など、利用者がまだ動いていない）だけ戻り先を控え、次の再ページ割りの報告で
    /// 保存した文へ戻す。動いた後の大きさの変化（読書中のドラッグ）は対象外（spec §2.4）。
    func hostViewDidResize() {
        guard restoredAnchor != nil else { return }
        captureRelandTarget()
    }

    private func cancelReland() { relandTarget = nil }

    // MARK: G56 Codex レビュー — Washi が内部で処理する入力（端タップ・リンク・ホイール）

    /// ホイール／トラックパッドの入力が本の面に来た（ページが送られたかは問わない）。控えだけを捨てる。
    /// Washi はホイールでのページ送りを内部で処理して host のメソッドを通らないため、再ページ割りの待ちの間に
    /// 送られた報告が先に来ると、控えた古い文へ引き戻してしまう。復元の保護は外さない — ページを送らない
    /// ホイール（量子化の閾値未満）で保護が外れると、開いて閉じただけで文が進行率に格下げされる。
    /// 実際にページが送られれば、報告の鍵が変わって保護は外れる。
    func userDidScrollWheel() { cancelReland() }

    /// 窓内のローカルモニタ（ホイール・スワイプ）。イベントは消費しない。
    private let wheelMonitor = LocalEventMonitor()

    /// `WashiHostView` が窓に載った／外れた。
    func hostViewDidChangeWindow() {
        guard hostView.window != nil else { wheelMonitor.uninstall(); return }
        wheelMonitor.install(matching: [.scrollWheel, .swipe]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.hostView.window, event.window === window else { return }
                let location = self.hostView.convert(event.locationInWindow, from: nil)
                guard self.hostView.bounds.contains(location) else { return }
                self.userDidScrollWheel()
            }
        }
    }

    /// 利用者の移動（ページ送り・本の端・全体ページ）。控えを捨て、復元の保護も外す
    /// （保護が残ると、移動の後の大きさの変化や報告で古い文へ引き戻しうる）。
    /// `go(to:)` は自分の引数で保護を張り直すので、これを使わない。
    private func userDidMove() {
        relandTarget = nil
        restoredAnchor = nil
    }

    /// 報告が anchor と同じ項目か（spine が同じで、idref が両方あれば一致）。
    private static func isSameItem(_ locator: EPUBLocator, as anchor: EPUBLocator) -> Bool {
        locator.spineIndex == anchor.spineIndex
            && (anchor.idref == nil || locator.idref == nil || anchor.idref == locator.idref)
    }

    /// テスト専用: 窓に載せずに「初回 load 済み」にする（load 自体は行わない）。
    func markLoadedForTesting() {
        hasPerformedInitialLoad = true
        pendingLoad = nil
    }

    /// `makeReaderView` が open 済みの publication を置いておく場所。窓に載って実寸が
    /// 決まるまでは load() を呼ばない（G48-2 smoke: 白紙表紙の修正）。
    private var pendingLoad: (publication: EPUBPublication, locator: EPUBLocator?)?
    private var hasPerformedInitialLoad = false

    override init() {
        hostView = WashiHostView(readerView: reader)
        super.init()
        hostView.host = self
        reader.delegate = self
        // G57（Codex P2）: 「コントラストを上げる」の切り替えで強制文字色の CSS を当て直す。tearDown で外す。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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

    /// `WashiHostView` からのみ呼ばれる。`hasPerformedInitialLoad` で二重実行を防ぐ。
    func performPendingLoad() {
        guard !hasPerformedInitialLoad, let pending = pendingLoad else { return }
        hasPerformedInitialLoad = true
        pendingLoad = nil
        let loadLine = "load: host=\(String(describing: self.hostView.bounds)) reader=\(String(describing: self.reader.bounds)) window=\(String(describing: self.hostView.window?.frame ?? .zero))"
        epubReaderLog.notice("\(loadLine, privacy: .public)")
        armRestoredAnchor(pending.locator)
        reader.load(publication: pending.publication, at: pending.locator)
    }

    var view: NSView { hostView }

    /// G54-S3c: 巻送りで窓から外すとき。コールバックと delegate を外し、`unload()` で WebView と
    /// 本の参照を放す。容れ物を親から外すと Washi は `viewDidMoveToWindow(nil)` で
    /// ネイティブキー監視（`forwardsKeyEventsNatively`）を外す — 残ると外した本がキーを横取りする。
    func tearDown() {
        // 走っている補完を無効にする。
        reportGeneration += 1
        restoredAnchor = nil
        relandTarget = nil
        wheelMonitor.uninstall()
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
        cancelReland()
        let mapped = WashiLocatorMapping.toWashi(locator)
        // G56-S2: 保護は load 前の分岐より前に張る（pending の差し替えでも着地で効く）。
        armRestoredAnchor(mapped)
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
    func goForward() { userDidMove(); reader.goForward() }
    func goBackward() { userDidMove(); reader.goBackward() }

    // MARK: G56-S3 — 見た目

    private(set) var appearance = EPUBAppearanceValue()
    /// 窓の実際の外観がダークか。テストで差し替える。
    lazy var systemIsDark: @MainActor () -> Bool = { [weak self] in
        guard let self else { return false }
        return self.hostView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// システムの「コントラストを上げる」が ON か。テストで差し替える。
    /// Washi は ON のとき背景と文字を純白／純黒に固定するので、強制文字色の CSS を外す判断に使う。
    lazy var increaseContrast: @MainActor () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// 欧文の書体名から、その字体（PostScript 名・太さ・斜体）を引く。テストで差し替える。
    /// 既定は `NSFontManager` に入っている字体。引けなければ空（CSS は書体名の並びに戻る）。
    lazy var resolveLatinFaces: @MainActor (String) -> [EPUBFontFace] = { family in
        Self.latinFaces(fromMembers: NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [])
    }

    /// 幅違いの字体の traits（narrow・expanded・condensed・compressed）。
    nonisolated static let widthTraits: UInt = NSFontTraitMask.narrowFontMask.rawValue
        | NSFontTraitMask.expandedFontMask.rawValue
        | NSFontTraitMask.condensedFontMask.rawValue
        | NSFontTraitMask.compressedFontMask.rawValue

    /// `availableMembers(ofFontFamily:)` の各項目（[PostScript 名, 字体名, 太さ 0–15, traits]）を字体に写す。
    /// 形の崩れた項目と幅違い（Condensed など）は捨てる。同じ (CSS の太さ, 斜体) が重なるときは最初の
    /// 字体（ファミリーの正規の並び）を採る。`@font-face` の記述子が同じだと WebKit は後の方を使うため、
    /// 重ねると Bold が Condensed Bold に、Regular が Ornaments に化ける。
    nonisolated static func latinFaces(fromMembers members: [[Any]]) -> [EPUBFontFace] {
        var seen = Set<[Int]>()
        return members.compactMap { m in
            guard m.count >= 4, let ps = m[0] as? String, !ps.isEmpty,
                  let weight = (m[2] as? NSNumber)?.intValue,
                  let traits = (m[3] as? NSNumber)?.uintValue,
                  traits & widthTraits == 0 else { return nil }
            let italic = traits & NSFontTraitMask.italicFontMask.rawValue != 0
            let face = EPUBFontFace(postScriptName: ps, weight: cssWeight(appKitWeight: weight), italic: italic)
            guard seen.insert([face.weight, italic ? 1 : 0]).inserted else { return nil }
            return face
        }
    }

    /// `NSFontManager` の太さ（0–15。5 が標準、9 が太字）を CSS の太さ（100–900）に写す。
    nonisolated static func cssWeight(appKitWeight w: Int) -> Int {
        switch w {
        case ...2: return 100
        case 3: return 200
        case 4: return 300
        case 5: return 400
        case 6: return 500
        case 7...8: return 600
        case 9...10: return 700
        case 11...12: return 800
        default: return 900
        }
    }

    func applyAppearance(_ appearance: EPUBAppearanceValue) {
        self.appearance = appearance
        var next = reader.settings
        switch appearance.theme {
        case .system: next.theme = .system
        case .light:  next.theme = .light
        case .dark:   next.theme = .dark
        }
        let colors = appearance.resolvedColors(systemIsDark: systemIsDark())
        next.backgroundColor = colors.background.map { EPUBRGBAColor(r: $0.r, g: $0.g, b: $0.b) }
        next.textColor = colors.text.map { EPUBRGBAColor(r: $0.r, g: $0.g, b: $0.b) }
        // G57: 書体・強制文字色は Washi の `fontFamilyOverride`（和文のみ・単一書体）ではなく、
        // 和文/欧文の両方と強制色をまとめて表せる `userCSS` で渡す。
        next.fontFamilyOverride = nil
        // 欧文の書体はラテン文字の範囲に限る（日本語の約物・かな・漢字は和文の書体へ落とす）。
        let latinFaces = appearance.latinFontFamily.flatMap { $0.isEmpty ? nil : resolveLatinFaces($0) } ?? []
        next.userCSS = EPUBAppearanceCSS.make(appearance, systemIsDark: systemIsDark(), latinFaces: latinFaces,
                                              increaseContrast: increaseContrast())
        next.forcesReadableColors = appearance.forcesReadableColors
        guard next != reader.settings else { return }   // 同値で再ページ割りを起こさない
        if next.userCSS != reader.settings.userCSS { captureRelandTarget() }
        reader.settings = next
    }

    // MARK: G57 — 横方向のホイールでのページ送り

    var horizontalWheelTurnsPages: Bool {
        get { reader.settings.horizontalWheelTurnsPages }
        set {
            guard reader.settings.horizontalWheelTurnsPages != newValue else { return }
            reader.settings.horizontalWheelTurnsPages = newValue
        }
    }

    var reversesHorizontalWheelTurn: Bool {
        get { reader.settings.reversesHorizontalWheelTurn }
        set {
            guard reader.settings.reversesHorizontalWheelTurn != newValue else { return }
            reader.settings.reversesHorizontalWheelTurn = newValue
        }
    }

    /// システムの外観が変わった（`theme == .system` のパレットを入れ替える）。
    func refreshAppearanceForSystemChange() { applyAppearance(appearance) }

    /// G57（Codex P2）: アクセシビリティの表示設定（コントラストを上げる）が変わった。
    /// 強制文字色の CSS の有無が変わるので当て直す。`NSWorkspace.shared.notificationCenter` から呼ばれる。
    @objc func accessibilityDisplayOptionsDidChange(_ note: Notification) {
        refreshAppearanceForSystemChange()
    }

    /// フォント倍率。Washi 側の許容範囲（`EPUBReaderView.fontScaleRange` = 0.5...3.0）へクランプする。
    /// 直接代入は delegate の `didChangeFontScale` を発火させない（Washi 自身がピンチ／
    /// `adjustFontScale(by:)` 経由でしか呼ばない）ので、App 層が復元値をここへ書き戻しても
    /// `onFontScaleChange` への往復（＝無駄な再保存）は起きない。
    var fontScale: Double {
        get { reader.settings.fontScale }
        set {
            let range = EPUBReaderView.fontScaleRange
            let clamped = min(range.upperBound, max(range.lowerBound, newValue))
            guard reader.settings.fontScale != clamped else { return }   // 同値なら再ページ割りも控えも起こさない
            captureRelandTarget()
            reader.settings.fontScale = clamped
        }
    }

    // MARK: G51 — 契約の追加分（Washi の公開 API へ委譲）

    func goToBookStart() { userDidMove(); reader.goToBookStart() }
    func goToBookEnd() { userDidMove(); reader.goToBookEnd() }
    /// Washi が RTL を見て goForward/goBackward に解く（G48-2 の native 経路と同じ）。
    func pageLeft() { userDidMove(); reader.turnPageLeft() }
    func pageRight() { userDidMove(); reader.turnPageRight() }

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
            captureRelandTarget()
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
        userDidMove()
        guard let locator = reader.censusLocator(forGlobalPage: page) else { return }
        reader.go(to: locator)
    }
    var spineItemCount: Int? {
        reader.publication?.readingOrder.count ?? pendingLoad?.publication.readingOrder.count
    }

    /// Washi と同じ計算（範囲へクランプし、差が 0.001 以下なら変えない）で、実際に変わるときだけ控える。
    /// 範囲の端で変化が無いと Washi は報告を出さないので、控えると無関係な次の報告（利用者の
    /// ページ送りなど）で文へ引き戻してしまう。
    func adjustFontScale(by delta: Double) {
        let range = EPUBReaderView.fontScaleRange
        let current = reader.settings.fontScale
        let target = min(range.upperBound, max(range.lowerBound, current + delta))
        if abs(target - current) > 0.001 { captureRelandTarget() }
        reader.adjustFontScale(by: delta)
    }
    /// 直接代入は Washi の `didChangeFontScale` を発火しないので、変化があれば自分で流す。
    func resetFontScale() {
        guard reader.settings.fontScale != 1.0 else { return }
        captureRelandTarget()
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
        reportGeneration += 1
        let generation = reportGeneration
        var reported = locator
        var guarded = false
        if var guardState = restoredAnchor {
            let key = LandingKey(spine: locator.spineIndex, progress: locator.progression)
            if guardState.landing == nil {
                // 着地は復元先と同じ spine（idref が両方あれば一致）の報告にだけ結ぶ。
                // Washi の移動が途中で戻った等で別の章の報告が先に来たら、保護を外す
                // （古い textOffset と idref を別の章へ付けると、次回は違う章で開いてしまう）。
                if Self.isSameItem(locator, as: guardState.anchor) {
                    guardState.landing = key
                    restoredAnchor = guardState
                }
            }
            if guardState.landing == key {
                reported.textOffset = guardState.anchor.textOffset
                reported.idref = guardState.anchor.idref ?? reported.idref
                guarded = true
            } else {
                restoredAnchor = nil
            }
        }
        publish(reported)
        // G56-S2: 設定変更の後の最初の報告（再ページ割り）なら、控えた文へ戻る。
        // 保護中の報告（下の早期 return）でも必ず通るよう、publish の直後に置く。
        // 戻るときは補完しない（すぐ着地の報告が来て上書きし、その報告は復元の保護で文を保つ）。
        // 戻るのは控えと同じ項目の報告のときだけ。別の章の報告（競合）なら戻らずに控えを捨てる。
        if let target = relandTarget {
            relandTarget = nil
            if now() <= target.deadline, Self.isSameItem(locator, as: target.anchor) {
                armRestoredAnchor(target.anchor)
                navigateReader(target.anchor)
                return
            }
        }
        // 保護中の報告は補完しない。補完はページ先頭の文を返すので、復元した文より前へ
        // ずれ、開いて閉じるたびに保存位置が後退する（spec §2.3: 動くまで復元のアンカーを保つ）。
        guard !guarded else { return }
        let fetch = fetchAnchoredLocator          // await の間 self を強参照で握らない
        Task { @MainActor [weak self] in
            let anchored = await fetch()
            guard let self,
                  generation == self.reportGeneration,
                  anchored.spineIndex == locator.spineIndex,
                  let offset = anchored.textOffset else { return }
            var enriched = locator            // 報告の spine/progress を保つ（持続の門は spine/progress で比べる）
            enriched.textOffset = offset
            enriched.idref = anchored.idref ?? locator.idref
            self.publish(enriched)
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
        // ピンチの経路: 通知は変更の後だが、再ページ割りは非同期なので lastPublished はまだ変更前の文。
        captureRelandTarget()
        onFontScaleChange?(scale)
    }

    /// ページ面のクリック（端タップのページ送りを含む）。Washi が内部で処理するので、控えだけを捨てる。
    /// 既定の動作（端タップ）は残す（false）。
    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool {
        cancelReland()
        return false
    }

    /// 本の中のリンク（同じ章を含む）。控えだけを捨て、既定どおり辿る。
    /// 別の位置へ着地すれば報告の鍵が変わり、復元の保護は外れる。
    func readerView(_ view: EPUBReaderView, shouldFollowInternalLink link: EPUBInternalLink) -> Bool {
        cancelReland()
        return true
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

/// `NSEvent` のローカルモニタの token を握る。deinit でも外す（host が tearDown を経ずに解放されても残さない）。
/// モニタは本の窓に限らずアプリ全体のイベントを見るので、handler 側で窓と位置を絞る。イベントは消費しない。
private final class LocalEventMonitor {
    private var token: Any?

    func install(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }
    }

    func uninstall() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { uninstall() }
}
