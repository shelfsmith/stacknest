// SPDX-License-Identifier: MIT
import AppKit
import os

/// G54-S3cd smoke fix: 巻送りでビューア種別が切り替わるとき（EPUB→画像ビューア／画像ビューア→EPUB）、
/// 旧窓を閉じた直後に新窓を全画面化しようとすると AppKit が `toggleFullScreen` を無視することがある
/// （旧窓の全画面 Space が退出アニメーション中のため）。
///
/// アプリ全体で「いまどの窓が全画面遷移の途中か」を窓ごとに持つ軽量トラッカー。
/// `willEnterFullScreen`/`willExitFullScreen` でその窓を集合へ挿入、対になる
/// `didEnterFullScreen`/`didExitFullScreen` で取り除く。各窓コントローラ自身の
/// `windowDidEnterFullScreen`（resume シート表示に使う）とは別の独立したオブザーバなので、
/// 既存の表示順序には影響しない。
///
/// G54-S3e smoke fix (自由記載): 以前は窓を区別しない単純なカウンタだった。`will*` に対応する `did*`
/// が来ない場面（窓が全画面のまま閉じられた／退出アニメーション中に AppKit が遷移を中断し再試行した）では
/// カウントが 0 に戻らず、以後ずっと `isOtherTransitionInProgress` が真になり続け、巻送りのたびに
/// 1.5 秒待ってから通常表示→全画面という劣化した見え方になっていた（`FullScreenEntryDriver.Config.
/// transitionWaitTimeout`）。窓ごとの `Set<ObjectIdentifier>` にすることで、同じ窓への重複した `will*` は
/// 冪等（集合への再挿入）になり、`NSWindow.willCloseNotification` でも取り除くことで「did* が永遠に来ない」
/// 経路を塞ぐ。
@MainActor
final class FullScreenTransitionTracker {
    static let shared = FullScreenTransitionTracker()

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "FullScreen")

    private(set) var transitioningWindows: Set<ObjectIdentifier> = []
    private var completionHandlers: [() -> Void] = []
    private var observers: [NSObjectProtocol] = []

    var isTransitioning: Bool { !transitioningWindows.isEmpty }

    /// `excluding` の窓自身は「他の窓」に数えない——自窓の遷移で自窓のドライバが待つのを防ぐ。
    func isTransitioning(excluding id: ObjectIdentifier) -> Bool {
        transitioningWindows.contains { $0 != id }
    }

    init() {
        let nc = NotificationCenter.default
        // レビュー Minor: `queue: .main` により実行は必ずメインスレッドだが、NotificationCenter の
        // `using:` クロージャの型自体は `@Sendable`（非隔離）なので、コンパイラは MainActor 隔離の
        // `begin()`/`end()` をここから直接は呼ばせない。`MainActor.assumeIsolated` で
        // 「実際にはメインスレッドで呼ばれる」という事実を型に伝える。
        // レビュー Minor（G54-S3e smoke fix）: `Notification`/`NSWindow` は非 Sendable なので、
        // `MainActor.assumeIsolated` の隔離クロージャへそのまま渡すと「sending risks causing data
        // races」で弾かれる。`ObjectIdentifier`（Sendable な値型）だけを隔離前に取り出して渡す。
        observers = [
            nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.begin(id) }
            },
            nc.addObserver(forName: NSWindow.willExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.begin(id) }
            },
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.end(id) }
            },
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.end(id) }
            },
            // G54-S3e smoke fix: did* を待たずに窓が閉じられた場合の取りこぼし対策。
            nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard let id = Self.windowID(note) else { return }
                MainActor.assumeIsolated { self?.closeWindow(id) }
            },
        ]
    }

    /// `note.object` を `NSWindow` として `ObjectIdentifier` に落とす。`nonisolated` のままでよい
    /// （オブジェクトの同一性を読むだけで、隔離されたプロパティには触れない）。
    private nonisolated static func windowID(_ note: Notification) -> ObjectIdentifier? {
        (note.object as? NSWindow).map(ObjectIdentifier.init)
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

    private func begin(_ id: ObjectIdentifier) {
        transitioningWindows.insert(id)
        Self.logger.debug("begin: transitioning=\(self.transitioningWindows.count, privacy: .public)")
    }

    private func end(_ id: ObjectIdentifier) {
        transitioningWindows.remove(id)
        Self.logger.debug("end: transitioning=\(self.transitioningWindows.count, privacy: .public)")
        fireCompletionHandlersIfIdle()
    }

    private func closeWindow(_ id: ObjectIdentifier) {
        transitioningWindows.remove(id)
        Self.logger.debug("close: transitioning=\(self.transitioningWindows.count, privacy: .public)")
        fireCompletionHandlersIfIdle()
    }

    private func fireCompletionHandlersIfIdle() {
        guard transitioningWindows.isEmpty, !completionHandlers.isEmpty else { return }
        let handlers = completionHandlers
        completionHandlers.removeAll()
        for h in handlers { h() }
    }

    /// テスト用: 集合を直接動かす（実ウィンドウ無しで「遷移中」を作るため）。
    /// `id` の元は何でもよい（`ObjectIdentifier(NSObject())` 等）——同一性だけを使う。
    func testBeginTransition(id: ObjectIdentifier) { begin(id) }
    func testEndTransition(id: ObjectIdentifier) { end(id) }
    func testCloseWindow(id: ObjectIdentifier) { closeWindow(id) }
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
    /// G54-S3e smoke fix: `isOtherTransitionInProgress` は自分が駆動している窓自身を除外する
    /// （`ObjectIdentifier` は値なので窓を強参照しない——弱参照の `window` とは別に保持してよい）。
    convenience init(window: NSWindow, config: Config = Config(),
                      tracker: FullScreenTransitionTracker = .shared) {
        let windowID = ObjectIdentifier(window)
        self.init(
            config: config,
            isFullScreen: { [weak window] in window?.styleMask.contains(.fullScreen) ?? true },
            isOtherTransitionInProgress: { tracker.isTransitioning(excluding: windowID) },
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
        // Codex P2: 他窓の遷移を待つ間にユーザーが手で全画面にしていることがある。`toggleFullScreen` は
        // トグルなので、ここで改めて確かめずに呼ぶと達成済みの全画面を解除してしまう。
        if isFullScreen() {
            isRunning = false
            return
        }
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
