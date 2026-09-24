// SPDX-License-Identifier: MIT
import AppKit

/// G54-S3cd smoke fix: 巻送りでビューア種別が切り替わるとき（EPUB→画像ビューア／画像ビューア→EPUB）、
/// 旧窓を閉じた直後に新窓を全画面化しようとすると AppKit が `toggleFullScreen` を無視することがある
/// （旧窓の全画面 Space が退出アニメーション中のため）。
///
/// アプリ全体で「いまどこかの窓が全画面遷移の途中か」を数えるだけの軽量トラッカー。
/// `willEnterFullScreen`/`willExitFullScreen` で +1、対になる `didEnterFullScreen`/`didExitFullScreen` で
/// -1 する。各窓コントローラ自身の `windowDidEnterFullScreen`（resume シート表示に使う）とは別の
/// 独立したオブザーバなので、既存の表示順序には影響しない。
@MainActor
final class FullScreenTransitionTracker {
    static let shared = FullScreenTransitionTracker()

    private(set) var transitioningCount = 0
    private var completionHandlers: [() -> Void] = []
    private var observers: [NSObjectProtocol] = []

    var isTransitioning: Bool { transitioningCount > 0 }

    init() {
        let nc = NotificationCenter.default
        // レビュー Minor: `queue: .main` により実行は必ずメインスレッドだが、NotificationCenter の
        // `using:` クロージャの型自体は `@Sendable`（非隔離）なので、コンパイラは MainActor 隔離の
        // `begin()`/`end()` をここから直接は呼ばせない。`MainActor.assumeIsolated` で
        // 「実際にはメインスレッドで呼ばれる」という事実を型に伝える。
        observers = [
            nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin() }
            },
            nc.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin() }
            },
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
        ]
    }

    @MainActor
    deinit {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
    }

    /// 現在進行中の遷移が 1 つも無くなった時点で一度だけ呼ばれる。
    /// 呼び出し時点で既に進行中の遷移が無ければ、次の tick で即座に呼ぶ
    /// （`schedule` 越しに呼ぶのは呼び出し側の責務。ここでは同期に呼んでよい）。
    func onNextTransitionEnd(_ handler: @escaping () -> Void) {
        if !isTransitioning {
            handler()
            return
        }
        completionHandlers.append(handler)
    }

    private func begin() {
        transitioningCount += 1
    }

    private func end() {
        transitioningCount = max(0, transitioningCount - 1)
        guard transitioningCount == 0, !completionHandlers.isEmpty else { return }
        let handlers = completionHandlers
        completionHandlers.removeAll()
        for h in handlers { h() }
    }

    /// テスト用: カウントを直接動かす（実ウィンドウ無しで「遷移中」を作るため）。
    func testBeginTransition() { begin() }
    func testEndTransition() { end() }
}

/// G54-S3cd smoke fix: 「全画面化を要求 → 検証 → 必要なら待つ／リトライ」の決定ロジック。
/// AppKit 呼び出し（実際の `toggleFullScreen`・`styleMask` 読み取り・タイマー・通知監視）は
/// すべて呼び出し側が注入するクロージャに追い出してあるので、本体はテストで実ウィンドウ無しに検証できる。
///
/// 手順:
/// 1. 既に全画面なら何もしない。
/// 2. 最初の試行だけ、他の窓が全画面遷移の途中なら、その遷移が終わるまで待ってから要求する
///    （待っている間はリトライ回数を消費しない）。
/// 3. 要求のたびに `retryInterval` 後に検証し、全画面になっていなければ再試行する
///    （`maxAttempts` 回まで）。
@MainActor
final class FullScreenEntryDriver {
    struct Config {
        var maxAttempts: Int = 3
        var retryInterval: TimeInterval = 0.3
        /// レビュー Important（Fix round 1）: 他窓の全画面遷移完了を待つ上限。
        /// `FullScreenTransitionTracker` は対応の取れていない単純なカウンタなので、
        /// `will*` に対応する `did*` が来ない場面（遷移中に窓が破棄される等）では
        /// カウントが戻らず、通知待ちが無期限になりうる。期限が来たら通知を待たずに進む。
        var transitionWaitTimeout: TimeInterval = 1.5
    }

    private let config: Config
    private let isFullScreen: () -> Bool
    private let isOtherTransitionInProgress: () -> Bool
    private let toggle: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let observeTransitionEnd: (@escaping () -> Void) -> Void

    private(set) var attemptsUsed = 0
    private var isRunning = false

    init(config: Config = Config(),
         isFullScreen: @escaping () -> Bool,
         isOtherTransitionInProgress: @escaping () -> Bool,
         toggle: @escaping () -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         observeTransitionEnd: @escaping (@escaping () -> Void) -> Void) {
        self.config = config
        self.isFullScreen = isFullScreen
        self.isOtherTransitionInProgress = isOtherTransitionInProgress
        self.toggle = toggle
        self.schedule = schedule
        self.observeTransitionEnd = observeTransitionEnd
    }

    /// 便利イニシャライザ: 実際の `NSWindow` とアプリ共有のトラッカーを使う。
    convenience init(window: NSWindow, config: Config = Config(),
                      tracker: FullScreenTransitionTracker = .shared) {
        self.init(
            config: config,
            isFullScreen: { [weak window] in window?.styleMask.contains(.fullScreen) ?? true },
            isOtherTransitionInProgress: { tracker.isTransitioning },
            toggle: { [weak window] in window?.toggleFullScreen(nil) },
            // レビュー Minor: `block`（`() -> Void`）は非 Sendable なので、そのまま `asyncAfter(execute:)`
            // （`@Sendable` を要求）へは渡せない。実行は必ずメインスレッドなので `MainActor.assumeIsolated`
            // で実行時に隔離を assert する薄いラッパーに包んで渡す。
            schedule: { delay, block in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { block() }
                }
            },
            observeTransitionEnd: { completion in tracker.onNextTransitionEnd(completion) }
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attemptsUsed = 0
        proceed()
    }

    /// テスト用: 実行を止めて以後のクロージャ呼び出しを無視させる。
    func stop() {
        isRunning = false
    }

    private func proceed() {
        guard isRunning else { return }
        if isFullScreen() {
            isRunning = false
            return
        }
        if attemptsUsed >= config.maxAttempts {
            isRunning = false
            return
        }
        if attemptsUsed == 0 && isOtherTransitionInProgress() {
            waitForOtherTransitionThenToggle()
            return
        }
        attemptToggle()
    }

    /// レビュー Important（Fix round 1）: 他窓の遷移完了通知と `transitionWaitTimeout` の期限の
    /// どちらか先に来た方で 1 回だけ前進する。`did*` 通知が永遠に来ない場合でも、期限を過ぎれば
    /// 通知を待たずに `attemptToggle()` へ進むので、待ちが無期限になることはない。
    /// 両方が来ても二重に進まないよう `hasProceeded` フラグで 1 回だけに絞る。
    private func waitForOtherTransitionThenToggle() {
        var hasProceeded = false
        let proceedOnce: () -> Void = { [weak self] in
            guard !hasProceeded else { return }
            hasProceeded = true
            self?.attemptToggle()
        }
        observeTransitionEnd(proceedOnce)
        schedule(config.transitionWaitTimeout, proceedOnce)
    }

    private func attemptToggle() {
        guard isRunning else { return }
        attemptsUsed += 1
        toggle()
        schedule(config.retryInterval) { [weak self] in self?.verify() }
    }

    private func verify() {
        guard isRunning else { return }
        if isFullScreen() {
            isRunning = false
            return
        }
        proceed()
    }
}
