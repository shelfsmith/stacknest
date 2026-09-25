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

/// `FullScreenTransitionTracker` の遷移中集合・完了通知の配線。
/// `testBeginTransition(id:)`/`testEndTransition(id:)`/`testCloseWindow(id:)` で実ウィンドウ無しに
/// 集合を動かして検証する（`ObjectIdentifier` の元は何でもよいので `NSObject()` を使う）。
/// 注意: `NSObject()` は他から強参照されていないと関数の残りの実行中に解放されうり、解放された
/// アドレスが次の `NSObject()` に再利用されて別々のつもりの `ObjectIdentifier` が衝突しかねない。
/// そのため各トークンはローカル変数で保持してテスト内で生存させる（`withExtendedLifetime` 相当）。
@MainActor
@Suite("FullScreenTransitionTracker: 窓ごとの遷移中集合")
struct FullScreenTransitionTrackerTests {
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
        let tokenA = NSObject()
        let tokenB = NSObject()
        let a = ObjectIdentifier(tokenA)
        let b = ObjectIdentifier(tokenB)
        tracker.testBeginTransition(id: a)
        tracker.testBeginTransition(id: b)   // 2 つの窓が同時に遷移中
        var fireCount = 0
        tracker.onNextTransitionEnd { fireCount += 1 }
        #expect(fireCount == 0, "遷移が残っている間は呼ばないこと")
        tracker.testEndTransition(id: a)
        #expect(fireCount == 0, "まだ 1 つ残っている間は呼ばないこと")
        tracker.testEndTransition(id: b)
        #expect(fireCount == 1, "集合が空に戻った時点で 1 回呼ぶこと")
        tracker.testEndTransition(id: b)   // 既に無い窓の余分な end
        #expect(fireCount == 1, "余分な end で再発火しないこと")
        withExtendedLifetime((tokenA, tokenB)) {}
    }

    /// G54-S3e smoke fix (自由記載): これが本来のバグの再現。AppKit が同じ窓に対して
    /// `will*` を 2 回発行し（退出アニメーション中の再試行等）、対応する `did*` が 1 回しか来ない
    /// 状況では、旧実装（無条件カウンタ）だとカウントが 1 のまま永遠に戻らず、以後すべての
    /// 全画面化要求が `isOtherTransitionInProgress` の 1.5 秒待ちを毎回踏んでいた。
    /// 窓ごとの集合なら、同じ窓の `will*` は重複して積まれない（Set の冪等性）ので
    /// `did*` 1 回で空に戻る。
    @Test("同じ窓への 2 回の will* の後、did* が 1 回来れば遷移なしに戻る")
    func repeatedBeginForSameWindowIsIdempotent() {
        let tracker = FullScreenTransitionTracker()
        let tokenA = NSObject()
        let a = ObjectIdentifier(tokenA)
        tracker.testBeginTransition(id: a)
        tracker.testBeginTransition(id: a)   // 同じ窓への 2 回目の will*（idempotent）
        #expect(tracker.isTransitioning)
        tracker.testEndTransition(id: a)     // did* は 1 回だけ
        #expect(!tracker.isTransitioning, "同じ窓の重複 begin は 1 回の end で解消すること")
        withExtendedLifetime(tokenA) {}
    }

    /// G54-S3e smoke fix (自由記載): 遷移の途中で窓が閉じられた場合（対応する did* が来ない）も、
    /// `willCloseNotification` 相当の経路で集合から取り除かれ、固まらないこと。
    @Test("遷移開始した窓が閉じられたら、遷移なしに戻り保留ハンドラが発火する")
    func closingATransitioningWindowClearsItAndFiresHandlers() {
        let tracker = FullScreenTransitionTracker()
        let tokenA = NSObject()
        let a = ObjectIdentifier(tokenA)
        tracker.testBeginTransition(id: a)
        var fireCount = 0
        tracker.onNextTransitionEnd { fireCount += 1 }
        #expect(fireCount == 0)
        tracker.testCloseWindow(id: a)   // did* が来ないまま窓が閉じた
        #expect(!tracker.isTransitioning, "did* を待たずに閉じた窓は取り除かれること")
        #expect(fireCount == 1, "保留していた完了ハンドラが発火すること")
        withExtendedLifetime(tokenA) {}
    }

    /// G54-S3e smoke fix: 自分自身が遷移中であることは、自分自身のドライバにとって
    /// 「他の窓」ではない——`isOtherTransitionInProgress` はこれで自窓を除外する。
    @Test("自窓の遷移は isTransitioning(excluding:) で「他」に数えない")
    func ownWindowIsNotCountedAsOther() {
        let tracker = FullScreenTransitionTracker()
        let tokenA = NSObject()
        let tokenB = NSObject()
        let a = ObjectIdentifier(tokenA)
        let b = ObjectIdentifier(tokenB)
        tracker.testBeginTransition(id: a)
        #expect(!tracker.isTransitioning(excluding: a), "自窓だけが遷移中なら「他」は無いこと")
        #expect(tracker.isTransitioning(excluding: b), "別の窓から見れば「他」が遷移中であること")
        withExtendedLifetime((tokenA, tokenB)) {}
    }
}
