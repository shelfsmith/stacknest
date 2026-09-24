// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest

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
}

/// `FullScreenTransitionTracker` のカウンタ・完了通知の配線。
/// `testBeginTransition`/`testEndTransition` で実ウィンドウ無しにカウントを動かして検証する。
@MainActor
@Suite("FullScreenTransitionTracker: 全画面遷移中カウンタ")
struct FullScreenTransitionTrackerTests {
    @Test("遷移が無ければ即座に完了ハンドラを呼ぶ")
    func firesImmediatelyWhenIdle() {
        let tracker = FullScreenTransitionTracker()
        var fired = false
        tracker.onNextTransitionEnd { fired = true }
        #expect(fired)
    }

    @Test("遷移中は完了ハンドラを保留し、カウントが 0 に戻った時点で 1 回だけ呼ぶ")
    func firesOnceWhenCountReturnsToZero() {
        let tracker = FullScreenTransitionTracker()
        tracker.testBeginTransition()
        tracker.testBeginTransition()   // 2 つの窓が同時に遷移中
        var fireCount = 0
        tracker.onNextTransitionEnd { fireCount += 1 }
        #expect(fireCount == 0, "遷移が残っている間は呼ばないこと")
        tracker.testEndTransition()
        #expect(fireCount == 0, "まだ 1 つ残っている間は呼ばないこと")
        tracker.testEndTransition()
        #expect(fireCount == 1, "カウントが 0 に戻った時点で 1 回呼ぶこと")
        tracker.testEndTransition()   // 0 未満に落ちないこと（余分な end）
        #expect(fireCount == 1, "余分な end で再発火しないこと")
    }
}
