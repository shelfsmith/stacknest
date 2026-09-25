// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppKit
@testable import StackNest

/// テスト専用のオフスクリーン窓。autosave 名を設定しない・タイトルも汎用のものにする・
/// 一度も画面に出さない等、ユーザーの環境（prefs・ウィンドウ配置の記憶）には一切触れない。
/// `FullScreenEntryDriverTests`・`FullScreenTransitionTrackerTests` の両方から使う共通ヘルパ。
@MainActor
private func makeTrackerTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    // ARC の最後の強参照が外れた時点で確実に解放されるようにする
    // （`isReleasedWhenClosed`（既定 true）は `close()` 時に AppKit 側からも解放を試みるので、
    // Swift 側で強参照管理する窓では二重解放を避けるため false にしておく）。
    window.isReleasedWhenClosed = false
    return window
}

/// G54-S3cd smoke fix: present() が要求した全画面化が、旧窓の全画面 Space 退出アニメーション中に
/// 無視されるのを吸収する `FullScreenEntryDriver` の決定ロジック。
///
/// 実ウィンドウの全画面遷移はテストで再現できない（画面が要る・アニメーションは非同期）ため、
/// AppKit 呼び出しはすべて注入したクロージャで代用し、「次に何をすべきか」の決定だけを検証する。
/// `schedule`/`observeTransitionEnd` は同期に即時実行するフェイクにして、待ち時間を消費しない。
@MainActor
@Suite("FullScreenEntryDriver: 全画面化の要求・検証・リトライ決定")
struct FullScreenEntryDriverTests {

    /// クロージャ呼び出しの記録と可変状態をまとめて持つフェイク一式。
    /// `FullScreenEntryDriver` の初期化子が MainActor 隔離のため、このネスト型も明示的に隔離する
    /// （外側の `@MainActor struct` の隔離は入れ子の型宣言には自動継承されない）。
    @MainActor
    final class Fakes {
        var fullScreen = false
        var otherTransitionInProgress = false
        var toggleCallCount = 0
        var scheduledDelays: [TimeInterval] = []
        var transitionEndObserverCount = 0

        /// toggle 呼び出しでは `fullScreen` を書き換えない（＝毎回失敗する想定）既定のドライバ。
        /// 成功させたいテストは自前で `FullScreenEntryDriver` を組み立てる。
        func makeDriver(maxAttempts: Int = 3, retryInterval: TimeInterval = 0.3) -> FullScreenEntryDriver {
            FullScreenEntryDriver(
                config: .init(maxAttempts: maxAttempts, retryInterval: retryInterval),
                isFullScreen: { [weak self] in self?.fullScreen ?? true },
                isOtherTransitionInProgress: { [weak self] in self?.otherTransitionInProgress ?? false },
                toggle: { [weak self] in self?.toggleCallCount += 1 },
                schedule: { [weak self] delay, block in
                    self?.scheduledDelays.append(delay)
                    block()   // 同期即時実行: テストで実待機しない
                },
                observeTransitionEnd: { [weak self] completion in
                    self?.transitionEndObserverCount += 1
                    completion()
                }
            )
        }
    }

    @Test("既に全画面なら toggle しない")
    func alreadyFullScreenDoesNothing() {
        let fakes = Fakes()
        fakes.fullScreen = true
        let driver = fakes.makeDriver()
        driver.start()
        #expect(fakes.toggleCallCount == 0)
        #expect(driver.attemptsUsed == 0)
    }

    @Test("他窓が遷移中でなければ、すぐ toggle して検証成功で終わる")
    func togglesImmediatelyWhenNoOtherTransition() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = false
        // toggle 呼び出しで成功したことにする（schedule は同期実行なので、
        // toggle 直後に fullScreen を立てておけば直後の検証に間に合う）。
        let driver = FullScreenEntryDriver(
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: {
                fakes.toggleCallCount += 1
                fakes.fullScreen = true   // 成功をシミュレート
            },
            schedule: { delay, block in fakes.scheduledDelays.append(delay); block() },
            observeTransitionEnd: { completion in fakes.transitionEndObserverCount += 1; completion() }
        )
        driver.start()
        #expect(fakes.toggleCallCount == 1)
        #expect(fakes.transitionEndObserverCount == 0, "他窓が遷移中でないなら待たずに要求する")
    }

    @Test("最初の試行だけ、他窓が遷移中なら完了を待ってから要求する")
    func waitsForOtherTransitionOnFirstAttemptOnly() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = true
        fakes.fullScreen = true   // toggle が呼ばれたら成功したことにする（下の toggle で反映）
        var toggleCount = 0
        let driver = FullScreenEntryDriver(
            isFullScreen: { toggleCount > 0 },   // toggle が 1 回呼ばれたら全画面達成
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: { toggleCount += 1 },
            schedule: { delay, block in fakes.scheduledDelays.append(delay); block() },
            observeTransitionEnd: { completion in fakes.transitionEndObserverCount += 1; completion() }
        )
        driver.start()
        #expect(fakes.transitionEndObserverCount == 1, "他窓の遷移完了を 1 回待つこと")
        #expect(toggleCount == 1, "待ってから 1 回だけ要求すること")
    }

    @Test("toggle が効かない場合、maxAttempts 回まで retryInterval 間隔でリトライしてから諦める")
    func retriesUpToMaxAttemptsThenGivesUp() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = false
        fakes.fullScreen = false   // 一度も成功しない状況をシミュレート
        let driver = fakes.makeDriver(maxAttempts: 3, retryInterval: 0.3)
        driver.start()
        #expect(fakes.toggleCallCount == 3, "maxAttempts 回だけ要求すること")
        #expect(driver.attemptsUsed == 3)
        #expect(fakes.scheduledDelays == [0.3, 0.3, 0.3], "検証はすべて retryInterval 後に行うこと")
    }

    @Test("2 回目の toggle で成功したら、それ以上リトライしない")
    func stopsRetryingOnceSucceeded() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = false
        var attempt = 0
        let driver = FullScreenEntryDriver(
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: {
                attempt += 1
                fakes.toggleCallCount += 1
                if attempt == 2 { fakes.fullScreen = true }   // 2 回目でようやく成功
            },
            schedule: { delay, block in fakes.scheduledDelays.append(delay); block() },
            observeTransitionEnd: { completion in fakes.transitionEndObserverCount += 1; completion() }
        )
        driver.start()
        #expect(fakes.toggleCallCount == 2)
        #expect(driver.attemptsUsed == 2)
    }

    @Test("stop() を呼んだ後は verify されても再試行しない")
    func stopPreventsFurtherRetries() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = false
        fakes.fullScreen = false
        var stopAfterFirstToggle: FullScreenEntryDriver?
        let driver = FullScreenEntryDriver(
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: {
                fakes.toggleCallCount += 1
                // 1 回目の toggle 直後（検証前）に窓が閉じられたことを模す。
                stopAfterFirstToggle?.stop()
            },
            schedule: { delay, block in fakes.scheduledDelays.append(delay); block() },
            observeTransitionEnd: { completion in completion() }
        )
        stopAfterFirstToggle = driver
        driver.start()
        #expect(fakes.toggleCallCount == 1, "stop() 後は再試行しないこと")
    }

    /// レビュー Important（Fix round 1）: `observeTransitionEnd` が呼んだ完了クロージャを握ったまま
    /// 二度と呼ばない状況（`will*` に対応する `did*` が来ない・遷移が壊れる等）でも、
    /// `config.transitionWaitTimeout` の期限が来れば待たずに `toggle` を試みること。
    @Test("他窓の遷移終了通知が来なくても、待ちの期限が来たら toggle を試みる")
    func timesOutWaitingForOtherTransitionAndTogglesAnyway() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = true
        fakes.fullScreen = false
        var timeoutBlock: (() -> Void)?
        let driver = FullScreenEntryDriver(
            config: .init(maxAttempts: 3, retryInterval: 0.3, transitionWaitTimeout: 1.5),
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: {
                fakes.toggleCallCount += 1
                fakes.fullScreen = true   // 1 回目の toggle で成功したことにする（有界リトライの巻き込みを避ける）
            },
            schedule: { delay, block in
                fakes.scheduledDelays.append(delay)
                if delay == 1.5 { timeoutBlock = block } else { block() }   // 検証(0.3秒)側は同期実行のまま
            },
            observeTransitionEnd: { _ in
                fakes.transitionEndObserverCount += 1
                // 実ウィンドウで通知が来ない状況を模す: 完了クロージャを一切呼ばない。
            }
        )
        driver.start()
        #expect(fakes.toggleCallCount == 0, "期限が来る前には toggle しないこと")
        #expect(timeoutBlock != nil, "待ちに期限をスケジュールすること")

        timeoutBlock?()   // 期限が来たことを模す

        #expect(fakes.toggleCallCount == 1, "期限後は通知を待たずに toggle を試みること")
    }

    /// 遷移終了通知と期限の両方が（遅れて）来ても、前進するのは 1 回だけであること。
    @Test("遷移終了通知と期限の両方が来ても、進むのは一度だけ")
    func onlyProceedsOnceEvenIfBothTransitionEndAndTimeoutFire() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = true
        fakes.fullScreen = false
        var transitionEndCompletion: (() -> Void)?
        var timeoutBlock: (() -> Void)?
        let driver = FullScreenEntryDriver(
            config: .init(maxAttempts: 3, retryInterval: 0.3, transitionWaitTimeout: 1.5),
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: {
                fakes.toggleCallCount += 1
                fakes.fullScreen = true   // 1 回目の toggle で成功したことにする
            },
            schedule: { delay, block in
                fakes.scheduledDelays.append(delay)
                if delay == 1.5 { timeoutBlock = block } else { block() }
            },
            observeTransitionEnd: { completion in transitionEndCompletion = completion }
        )
        driver.start()
        #expect(fakes.toggleCallCount == 0)

        transitionEndCompletion?()   // 先に通知が来た
        #expect(fakes.toggleCallCount == 1)

        timeoutBlock?()   // 遅れて期限も来た
        #expect(fakes.toggleCallCount == 1, "二重に前進しないこと（toggle が 2 回呼ばれない）")
    }

    /// Codex P2: 他窓の遷移を待っている間に（ユーザーの操作などで）全画面になったら、
    /// 待ちが明けても toggle しない（トグルなので、呼ぶと達成済みの全画面を解除してしまう）。
    @Test("待ちの間に全画面になったら、待ちが明けても toggle しない")
    func doesNotToggleIfFullScreenReachedDuringWait() {
        let fakes = Fakes()
        fakes.otherTransitionInProgress = true
        fakes.fullScreen = false
        var transitionEndCompletion: (() -> Void)?
        var timeoutBlock: (() -> Void)?
        let driver = FullScreenEntryDriver(
            config: .init(maxAttempts: 3, retryInterval: 0.3, transitionWaitTimeout: 1.5),
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: { fakes.toggleCallCount += 1; fakes.fullScreen.toggle() },
            schedule: { delay, block in
                fakes.scheduledDelays.append(delay)
                if delay == 1.5 { timeoutBlock = block } else { block() }
            },
            observeTransitionEnd: { completion in transitionEndCompletion = completion }
        )
        driver.start()
        fakes.fullScreen = true   // 待ちの間にユーザーが手で全画面にした

        transitionEndCompletion?()
        timeoutBlock?()

        #expect(fakes.toggleCallCount == 0, "達成済みの全画面をトグルで解除しないこと")
        #expect(fakes.fullScreen)
        #expect(driver.attemptsUsed == 0)
    }

    @Test("start() を二重に呼んでも多重実行しない")
    func startIsIdempotentWhileRunning() {
        let fakes = Fakes()
        // schedule を「即時実行しない」フェイクにして、1 回目の start() が verify 前で止まった
        // 状態を作る（＝実行中の driver に対する 2 回目の start() を試す）。
        var scheduledBlocks: [() -> Void] = []
        let driver = FullScreenEntryDriver(
            isFullScreen: { fakes.fullScreen },
            isOtherTransitionInProgress: { fakes.otherTransitionInProgress },
            toggle: { fakes.toggleCallCount += 1 },
            schedule: { _, block in scheduledBlocks.append(block) },
            observeTransitionEnd: { completion in completion() }
        )
        driver.start()
        #expect(fakes.toggleCallCount == 1)
        driver.start()   // まだ verify 前（実行中）なので何もしないこと
        #expect(fakes.toggleCallCount == 1, "実行中の二重 start() は無視すること")
        withExtendedLifetime(scheduledBlocks) {}
    }

    // MARK: - G54-S3e beep fix: 実際の FullScreenTransitionTracker との結線（beep-fix-brief.md）
    //
    // 以下 2 件は `isOtherTransitionInProgress`/`observeTransitionEnd` を実際の
    // `FullScreenTransitionTracker` に結線し、「Space 退出保留」がドライバの待ち合わせに正しく
    // 効くことを検証する（`toggle`/`isFullScreen`/`schedule` は他のテストと同じくフェイク）。

    /// 「space-exit pending 中に開始したドライバは待ち、Space 変化の通知で 1 回だけ toggle する」
    /// （brief のテスト項目）。
    @Test("Space 退出保留中に開始したドライバは待ち、Space 変化の通知で 1 回だけ toggle する")
    func waitsDuringSpaceExitPendingAndTogglesOnceAfterSpaceChange() {
        let tracker = FullScreenTransitionTracker()
        let oldWindow = makeTrackerTestWindow()
        tracker.testCloseWindow(id: ObjectIdentifier(oldWindow), wasFullScreen: true)   // Space 退出保留

        var fullScreen = false
        var toggleCallCount = 0
        var scheduledDelays: [TimeInterval] = []
        let driver = FullScreenEntryDriver(
            config: .init(transitionWaitTimeout: 1.5),
            isFullScreen: { fullScreen },
            isOtherTransitionInProgress: { tracker.isTransitioning },
            toggle: { toggleCallCount += 1; fullScreen = true },
            // transitionWaitTimeout(1.5秒) のスケジュールだけは即時実行しない（期限で待ちが明けた
            // ことにしてしまうと、Space 変化を待つ検証にならない）。retryInterval(0.3秒)は同期実行のまま。
            schedule: { delay, block in
                scheduledDelays.append(delay)
                if delay == 1.5 { /* 期限は来させない: Space 変化だけで待ちが明くことを確かめる */ } else { block() }
            },
            observeTransitionEnd: { completion in tracker.onNextTransitionEnd(completion) }
        )
        driver.start()
        #expect(toggleCallCount == 0, "Space 退出保留中は toggle しないこと")

        tracker.testActiveSpaceDidChange()   // Space 変化の通知が来た
        #expect(toggleCallCount == 1, "Space 変化で待ちが明けたら 1 回だけ toggle すること")

        withExtendedLifetime(oldWindow) {}
    }

    /// 「failed entry → next retry waits for space change/timeout, not 0.3 s」（brief のテスト項目）。
    /// `schedule` は即時実行しないフェイクにして、AppKit の `windowDidFailToEnterFullScreen`
    /// （= `driver.entryFailed()`）が verify() より先に届く実機の順序を模す。
    @Test("failed entry の後は、次のリトライも Space 変化/期限を待つ（盲目の 0.3 秒連打をしない）")
    func entryFailedMakesNextRetryWaitForSpaceChangeInsteadOfBlindRetry() {
        let tracker = FullScreenTransitionTracker()
        var fullScreen = false
        var toggleCallCount = 0
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        var driver: FullScreenEntryDriver!
        driver = FullScreenEntryDriver(
            isFullScreen: { fullScreen },
            isOtherTransitionInProgress: { tracker.isTransitioning },
            toggle: { toggleCallCount += 1 },   // 常に失敗する想定（fullScreen を立てない）
            schedule: { delay, block in scheduledBlocks.append((delay, block)) },
            observeTransitionEnd: { completion in tracker.onNextTransitionEnd(completion) }
        )
        driver.start()   // この時点では他窓の遷移も Space 保留も無いので、1 回目は即座に toggle する
        #expect(toggleCallCount == 1)
        #expect(scheduledBlocks.count == 1, "verify() が retryInterval 後にスケジュールされること")
        #expect(scheduledBlocks[0].delay == 0.3)

        // AppKit が windowDidFailToEnterFullScreen を呼んだことを模す（verify() が走るより先）。
        driver.entryFailed()
        // ちょうどこのタイミングで、旧窓が全画面のまま閉じて Space 退出保留になったとする
        // （実機ログどおり: 旧窓 close → 新窓 toggleFullScreen 失敗、がほぼ同時に起きる）。
        let oldWindow = makeTrackerTestWindow()
        tracker.testCloseWindow(id: ObjectIdentifier(oldWindow), wasFullScreen: true)

        // verify() が走る（isFullScreen() はまだ false）→ proceed() は entryFailed のフラグにより
        // 盲目に attemptToggle しない。
        let verifyBlock = scheduledBlocks.removeFirst().block
        verifyBlock()
        #expect(toggleCallCount == 1, "entryFailed 後は、Space 退出保留が残っていれば即座に再試行しないこと")

        tracker.testActiveSpaceDidChange()
        #expect(toggleCallCount == 2, "Space 変化が来たら 1 回だけ再試行すること")

        withExtendedLifetime(oldWindow) {}
    }
}

/// `FullScreenTransitionTracker` の遷移中集合・完了通知の配線。
///
/// G54-S3e ハードニングで、集合の要素が「弱参照の窓＋クエリ時の生死/経過時間プルーニング」に
/// 変わったため、`testBeginTransition` は（以前の任意の `NSObject()` トークンではなく）実際の
/// `NSWindow` を要求する。テストはユーザーの prefs に触れないテスト専用のオフスクリーン窓
/// （`makeTrackerTestWindow()`）を使う。
///
/// fix round 1（controller ruling）: プルーニング条件から `isVisible` は撤回された（全画面
/// アニメーション中の可視性反転で本当に遷移中の窓を誤って落としうるため）ので、テストの窓は
/// 画面に出す必要が無い——`orderFrontRegardless()`/`orderOut()` の往復は不要になった。
/// 経過時間の判定（`staleAge`）はテストの時計注入（`FullScreenTransitionTracker(staleAge:now:)`）で
/// スリープせずに検証する。
@MainActor
@Suite("FullScreenTransitionTracker: 窓ごとの遷移中集合")
struct FullScreenTransitionTrackerTests {

    /// テスト専用のオフスクリーン窓。autosave 名を設定しない・タイトルも汎用のものにする・
    /// 一度も画面に出さない等、ユーザーの環境（prefs・ウィンドウ配置の記憶）には一切触れない。
    private func makeTrackerTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // ARC の最後の強参照が外れた時点で確実に解放されるようにする
        // （`isReleasedWhenClosed`（既定 true）は `close()` 時に AppKit 側からも解放を試みるので、
        // Swift 側で強参照管理する窓では二重解放を避けるため false にしておく）。
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("遷移が無ければ即座に完了ハンドラを呼ぶ")
    func firesImmediatelyWhenIdle() {
        let tracker = FullScreenTransitionTracker()
        var fired = false
        tracker.onNextTransitionEnd { fired = true }
        #expect(fired)
    }

    @Test("2 つの窓が同時に遷移中なら、両方が終わるまで完了ハンドラを保留する")
    func firesOnceWhenAllWindowsFinish() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()
        let windowB = makeTrackerTestWindow()
        let a = ObjectIdentifier(windowA)
        let b = ObjectIdentifier(windowB)
        tracker.testBeginTransition(window: windowA)
        tracker.testBeginTransition(window: windowB)   // 2 つの窓が同時に遷移中
        var fireCount = 0
        tracker.onNextTransitionEnd { fireCount += 1 }
        #expect(fireCount == 0, "遷移が残っている間は呼ばないこと")
        tracker.testEndTransition(id: a)
        #expect(fireCount == 0, "まだ 1 つ残っている間は呼ばないこと")
        tracker.testEndTransition(id: b)
        #expect(fireCount == 1, "集合が空に戻った時点で 1 回呼ぶこと")
        tracker.testEndTransition(id: b)   // 既に無い窓の余分な end
        #expect(fireCount == 1, "余分な end で再発火しないこと")
    }

    /// G54-S3e smoke fix (自由記載): これが本来のバグの再現。AppKit が同じ窓に対して
    /// `will*` を 2 回発行し（退出アニメーション中の再試行等）、対応する `did*` が 1 回しか来ない
    /// 状況では、旧実装（無条件カウンタ）だとカウントが 1 のまま永遠に戻らず、以後すべての
    /// 全画面化要求が `isOtherTransitionInProgress` の 1.5 秒待ちを毎回踏んでいた。
    /// 窓ごとの集合なら、同じ窓の `will*` は重複して積まれない（辞書キーの冪等な上書き）ので
    /// `did*` 1 回で空に戻る。
    @Test("同じ窓への 2 回の will* の後、did* が 1 回来れば遷移なしに戻る")
    func repeatedBeginForSameWindowIsIdempotent() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()
        let a = ObjectIdentifier(windowA)
        tracker.testBeginTransition(window: windowA)
        tracker.testBeginTransition(window: windowA)   // 同じ窓への 2 回目の will*（idempotent）
        #expect(tracker.isTransitioning)
        tracker.testEndTransition(id: a)     // did* は 1 回だけ
        #expect(!tracker.isTransitioning, "同じ窓の重複 begin は 1 回の end で解消すること")
    }

    /// G54-S3e smoke fix (自由記載): 遷移の途中で窓が閉じられた場合（対応する did* が来ない）も、
    /// `willCloseNotification` 相当の経路で集合から取り除かれ、固まらないこと。
    @Test("遷移開始した窓が閉じられたら、遷移なしに戻り保留ハンドラが発火する")
    func closingATransitioningWindowClearsItAndFiresHandlers() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()
        let a = ObjectIdentifier(windowA)
        tracker.testBeginTransition(window: windowA)
        var fireCount = 0
        tracker.onNextTransitionEnd { fireCount += 1 }
        #expect(fireCount == 0)
        tracker.testCloseWindow(id: a)   // did* が来ないまま窓が閉じた
        #expect(!tracker.isTransitioning, "did* を待たずに閉じた窓は取り除かれること")
        #expect(fireCount == 1, "保留していた完了ハンドラが発火すること")
    }

    /// G54-S3e smoke fix: 自分自身が遷移中であることは、自分自身のドライバにとって
    /// 「他の窓」ではない——`isOtherTransitionInProgress` はこれで自窓を除外する。
    @Test("自窓の遷移は isTransitioning(excluding:) で「他」に数えない")
    func ownWindowIsNotCountedAsOther() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()
        let windowB = makeTrackerTestWindow()
        let a = ObjectIdentifier(windowA)
        let b = ObjectIdentifier(windowB)
        tracker.testBeginTransition(window: windowA)
        #expect(!tracker.isTransitioning(excluding: a), "自窓だけが遷移中なら「他」は無いこと")
        #expect(tracker.isTransitioning(excluding: b), "別の窓から見れば「他」が遷移中であること")
    }

    /// G54-S3e ハードニング: `onNextTransitionEnd` も `isTransitioning(excluding:)` と対称に
    /// `excluding` を持つ。自窓しか遷移中でなければ、自窓を除外した完了通知は待たずに即座に発火する
    /// （そうでなければ、ドライバは自分自身の遷移完了を待って自分自身を待つことになる）。
    @Test("onNextTransitionEnd(excluding:) は自窓の遷移だけが残っていれば即座に発火する")
    func onNextTransitionEndExcludingOwnWindowFiresImmediately() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()
        let a = ObjectIdentifier(windowA)
        tracker.testBeginTransition(window: windowA)

        var firedExcludingSelf = false
        tracker.onNextTransitionEnd(excluding: a) { firedExcludingSelf = true }
        #expect(firedExcludingSelf, "自窓しか遷移していないなら excluding: 付きは即座に発火すること")

        var firedGlobal = false
        tracker.onNextTransitionEnd { firedGlobal = true }
        #expect(!firedGlobal, "excluding 無しなら自窓の遷移も待つこと")

        tracker.testEndTransition(id: a)
        #expect(firedGlobal, "自窓の遷移が終われば無条件版も発火すること")
    }

    /// G54-S3e ハードニング: 保留中の `excluding:` 付き完了通知は、自窓以外の窓が終わった時点で
    /// 発火する——自窓自身はまだ遷移中のままでよい。
    @Test("onNextTransitionEnd(excluding:) は保留中でも自窓以外が終われば発火する")
    func onNextTransitionEndExcludingFiresWhenOthersFinishEvenIfSelfStillTransitioning() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()   // 自窓のつもり
        let windowB = makeTrackerTestWindow()   // 他窓のつもり
        let a = ObjectIdentifier(windowA)
        let b = ObjectIdentifier(windowB)
        tracker.testBeginTransition(window: windowA)
        tracker.testBeginTransition(window: windowB)

        var fired = false
        tracker.onNextTransitionEnd(excluding: a) { fired = true }
        #expect(!fired, "他窓 B がまだ遷移中なので発火しないこと")

        tracker.testEndTransition(id: b)
        #expect(fired, "他窓が終われば、自窓 A がまだ遷移中でも発火すること")
    }

    /// G54-S3e ハードニング: 窓が解放されたら（`will*` に対応する `did*` も `willClose` も来なくても）
    /// クエリのたびのプルーニングで集合から取り除かれ、保留中の完了ハンドラも発火すること。
    /// `autoreleasepool` で囲み、生成時に AppKit 内部が作る可能性のある一時的な自動解放参照まで
    /// スコープの終わりで確実に排水してから検証する（デタミニスティックな解放。fix round 1 で
    /// `isVisible` 条件を撤回したことで、この窓はそもそも画面に出す必要が無くなっている）。
    @Test("窓が解放されたら遷移エントリはプルーニングで消え、保留ハンドラが発火する")
    func prunesReleasedWindowAndFiresPendingHandlers() {
        let tracker = FullScreenTransitionTracker()
        var fired = false

        autoreleasepool {
            var window: NSWindow? = makeTrackerTestWindow()
            tracker.testBeginTransition(window: window!)
            #expect(tracker.isTransitioning, "begin 直後は遷移中であること")

            tracker.onNextTransitionEnd { fired = true }
            #expect(!fired, "まだ解放されていないので発火しないこと")

            window = nil   // 唯一の強参照を手放す → 画面に出していない窓なので
                            // AppKit 側の保持は無く、このスコープの終わりで確実に解放される
        }

        #expect(!tracker.isTransitioning, "解放された窓のエントリはプルーニングで取り除かれること")
        #expect(fired, "プルーニングで空になった時点で保留ハンドラが発火すること")
    }

    /// G54-S3e ハードニング fix round 1（controller ruling）: `isVisible` によるプルーニングは
    /// 撤回された（全画面アニメーション中の可視性反転で本当に遷移中の窓を誤って落としうるため）。
    /// 代わりに `staleAge` を超えた経過時間で判定する。スリープを避けるため、偽の時計
    /// （`FullScreenTransitionTracker(staleAge:now:)`）を注入する。
    /// あわせて、同じ窓への 2 回目の `will*`（`begin` の再呼び出し）が `beganAt` を
    /// リフレッシュすることも検証する——最初の `begin` からの通算では `staleAge` を超えていても、
    /// 直近の `begin` からは超えていなければ、まだ遷移中のまま扱われること。
    @Test("staleAge を超えて did*/willClose が来ない窓の遷移エントリはプルーニングで消える（偽の時計）")
    func prunesStaleTransitioningWindowUsingFakeClock() {
        var clockValue: TimeInterval = 0
        let tracker = FullScreenTransitionTracker(staleAge: 3.0, now: { clockValue })
        let window = makeTrackerTestWindow()

        tracker.testBeginTransition(window: window)
        #expect(tracker.isTransitioning, "begin 直後は遷移中であること")

        clockValue += 2.9   // staleAge (3.0 秒) 未満はまだ壊れた遷移とみなさない
        #expect(tracker.isTransitioning, "staleAge 未満ならまだ遷移中のまま")

        // 同じ窓への 2 回目の will*（AppKit が退出アニメーション中に再試行する等）は beganAt を
        // リフレッシュする。
        tracker.testBeginTransition(window: window)
        clockValue += 2.9   // 最初の begin からは通算 5.8 秒（staleAge 超過）だが、
                            // リフレッシュ後からはまだ 2.9 秒
        #expect(tracker.isTransitioning, "will* のリフレッシュ後は、そこからの経過時間で判定すること")

        clockValue += 0.2   // リフレッシュ後から合計 3.1 秒 > staleAge(3.0 秒)
        #expect(!tracker.isTransitioning, "リフレッシュ後も staleAge を超えたらプルーニングで取り除かれること")

        withExtendedLifetime(window) {}
    }

    /// G54-S3e ハードニング fix round 1: `fireReadyCompletions()` はハンドラを呼ぶ前に
    /// `pendingCompletions` を「まだ待つもの」へ確定させてから「発火するもの」を呼ぶ。
    /// これにより、完了ハンドラの中から新たに `onNextTransitionEnd` を登録するという
    /// 再入的な操作をしても、取りこぼしたり（登録が後の代入で消える）二重発火したり
    /// （再入した `fireReadyCompletions()` が同じものをもう一度処理する）しないこと。
    @Test("完了ハンドラの中から新たに onNextTransitionEnd を登録しても取りこぼさない・二重発火しない")
    func fireReadyCompletionsIsSafeAgainstReentrantRegistration() {
        let tracker = FullScreenTransitionTracker()
        let windowA = makeTrackerTestWindow()   // 自窓のつもり（最後まで遷移中に残す）
        let windowB = makeTrackerTestWindow()   // 他窓のつもり（先に終わる）
        let a = ObjectIdentifier(windowA)
        let b = ObjectIdentifier(windowB)
        tracker.testBeginTransition(window: windowA)
        tracker.testBeginTransition(window: windowB)

        var outerFireCount = 0
        var innerFireCount = 0
        tracker.onNextTransitionEnd(excluding: a) {
            outerFireCount += 1
            // ハンドラの中から新たに登録する（再入）。A がまだ遷移中なので、これはすぐには
            // 発火せず保留されるはず——取りこぼされていないかを後で確かめる。
            tracker.onNextTransitionEnd { innerFireCount += 1 }
        }

        tracker.testEndTransition(id: b)   // B が終わる → outer が発火し、その中で inner を登録
        #expect(outerFireCount == 1, "outer は 1 回だけ発火すること")
        #expect(innerFireCount == 0, "A がまだ遷移中なので inner はまだ発火しないこと（取りこぼされてもいない）")

        tracker.testEndTransition(id: a)   // A も終わる → 保留されていた inner が発火する
        #expect(innerFireCount == 1, "保留されていた inner がここで発火すること（取りこぼされていない）")
        #expect(outerFireCount == 1, "outer は二重発火しないこと")
    }

    // MARK: - G54-S3e beep fix: Space 退出保留（beep-fix-brief.md）

    /// 全画面のまま閉じた窓（`wasFullScreen: true`）は、`NSWorkspace.activeSpaceDidChangeNotification`
    /// が来るまで「遷移中」扱いのままであること。
    @Test("wasFullScreen=true で閉じた窓は、Space 変化通知が来るまで isTransitioning を真にする")
    func closeWithWasFullScreenTrueKeepsTransitioningUntilSpaceChanges() {
        let tracker = FullScreenTransitionTracker()
        let window = makeTrackerTestWindow()
        let id = ObjectIdentifier(window)
        #expect(!tracker.isTransitioning, "閉じる前は遷移中でないこと")

        tracker.testCloseWindow(id: id, wasFullScreen: true)
        #expect(tracker.isTransitioning, "全画面のまま閉じた直後は Space 退出保留として遷移中扱いにすること")

        tracker.testActiveSpaceDidChange()
        #expect(!tracker.isTransitioning, "Space 変化通知が来たら保留が解けること")
    }

    /// 全画面でなかった窓の close は、従来どおり Space 退出保留を立てないこと（回帰防止）。
    @Test("wasFullScreen=false で閉じても Space 退出保留は立たない")
    func closeWithWasFullScreenFalseDoesNotSetSpaceExitPending() {
        let tracker = FullScreenTransitionTracker()
        let window = makeTrackerTestWindow()
        tracker.testCloseWindow(id: ObjectIdentifier(window), wasFullScreen: false)
        #expect(!tracker.isTransitioning, "全画面でなかった窓の close は Space 退出保留を立てないこと")
    }

    /// Space 退出保留はデスクトップ全体に効くので、`excluding:` で閉じた窓自身を除外しても
    /// （もちろん別窓を除外しても）「他」として数え続けること。
    @Test("Space 退出保留は excluding: に関係なく「他」に数える")
    func spaceExitPendingCountsAsOtherRegardlessOfExcluding() {
        let tracker = FullScreenTransitionTracker()
        let closedWindow = makeTrackerTestWindow()
        let closedID = ObjectIdentifier(closedWindow)
        tracker.testCloseWindow(id: closedID, wasFullScreen: true)

        let otherID = ObjectIdentifier(makeTrackerTestWindow())
        #expect(tracker.isTransitioning(excluding: otherID), "別窓を除外しても Space 保留は他窓に効くこと")
        #expect(tracker.isTransitioning(excluding: closedID), "閉じた窓自身を除外しても Space 保留は効くこと")
    }

    /// `NSWorkspace.activeSpaceDidChangeNotification` が来ない場合の保険: `spaceExitTimeout` を
    /// 超えた経過時間でプルーニングされて消えること（偽の時計でスリープを避ける）。
    @Test("Space 退出保留は spaceExitTimeout を超えたらプルーニングで消える（偽の時計）")
    func spaceExitPendingClearsAfterSpaceExitTimeoutUsingFakeClock() {
        var clockValue: TimeInterval = 0
        let tracker = FullScreenTransitionTracker(spaceExitTimeout: 1.2, now: { clockValue })
        let window = makeTrackerTestWindow()
        tracker.testCloseWindow(id: ObjectIdentifier(window), wasFullScreen: true)
        #expect(tracker.isTransitioning)

        clockValue += 1.1
        #expect(tracker.isTransitioning, "spaceExitTimeout (1.2 秒) 未満はまだ保留のまま")

        clockValue += 0.2   // 合計 1.3 秒 > 1.2 秒
        #expect(!tracker.isTransitioning, "spaceExitTimeout を超えたら保留は自己修復で消えること")
    }
}

/// G54-S3e beep 診断: `DiagnosticViewerWindow` は `noResponder(for:)` をフックしてログを残すだけで、
/// 必ず `super` に委譲する（挙動＝ビープが鳴るかどうかは変えない）。実際にビープが鳴るかは
/// テスト環境では確認できない（`NSApp.currentEvent` も nil のまま）ので、安価なスモークテストとして
/// 「クラッシュせずに呼べる」ことだけを確かめる（brief 項目 4 の optional なテスト）。
@MainActor
@Suite("DiagnosticViewerWindow: noResponder(for:) フック")
struct DiagnosticViewerWindowTests {
    @Test("keyDown 以外・keyDown のどちらでもクラッシュせず super へ委譲する")
    func noResponderForwardsToSuperWithoutCrashing() {
        let window = DiagnosticViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.diagnosticKind = "image"

        window.noResponder(for: #selector(NSResponder.keyDown(with:)))
        window.noResponder(for: #selector(NSResponder.mouseDown(with:)))

        #expect(true, "例外・クラッシュ無く完了すること")
    }
}
