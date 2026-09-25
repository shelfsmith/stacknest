// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppKit
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
///
/// G54-S3e ハードニングで、集合の要素が「弱参照の窓＋クエリ時の `isVisible`/生死プルーニング」に
/// 変わったため、`testBeginTransition` は（以前の任意の `NSObject()` トークンではなく）実際の
/// `NSWindow` を要求する。テストはユーザーの prefs に触れないテスト専用のオフスクリーン窓
/// （`makeTrackerTestWindow()`）を使い、各窓は使い終えたら `orderOut` で画面から外す。
///
/// プルーニングは「表示中である」ことも遷移中の条件に含める（`orderOut` は `willCloseNotification`
/// を発火しないため、可視性そのものを見ないと取りこぼす経路がある）。そのため、集合の意味づけだけを
/// 検証したいテストでも `orderFrontRegardless()` で明示的に表示してから `begin` する——表示していない
/// 窓は `begin` した直後のクエリで（可視性プルーニングにより）即座に取り除かれてしまうため。
@MainActor
@Suite("FullScreenTransitionTracker: 窓ごとの遷移中集合")
struct FullScreenTransitionTrackerTests {

    /// テスト専用のオフスクリーン窓。autosave 名を設定しない・タイトルも汎用のものにする等、
    /// ユーザーの環境（prefs・ウィンドウ配置の記憶）には一切触れない。
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
        windowA.orderFrontRegardless()
        windowB.orderFrontRegardless()
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }
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
        windowA.orderFrontRegardless()
        defer { windowA.orderOut(nil) }
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
        windowA.orderFrontRegardless()
        defer { windowA.orderOut(nil) }
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
        windowA.orderFrontRegardless()
        windowB.orderFrontRegardless()
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }
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
        windowA.orderFrontRegardless()
        defer { windowA.orderOut(nil) }
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
        windowA.orderFrontRegardless()
        windowB.orderFrontRegardless()
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }
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
    /// `autoreleasepool` で囲み、`orderFrontRegardless()` 等 AppKit 内部が作る可能性のある
    /// 一時的な自動解放参照までスコープの終わりで確実に排水してから検証する（デタミニスティックな解放）。
    @Test("窓が解放されたら遷移エントリはプルーニングで消え、保留ハンドラが発火する")
    func prunesReleasedWindowAndFiresPendingHandlers() {
        let tracker = FullScreenTransitionTracker()
        var fired = false

        autoreleasepool {
            var window: NSWindow? = makeTrackerTestWindow()
            window!.orderFrontRegardless()
            tracker.testBeginTransition(window: window!)
            #expect(tracker.isTransitioning, "表示中の窓を begin した直後は遷移中であること")

            tracker.onNextTransitionEnd { fired = true }
            #expect(!fired, "まだ解放されていないので発火しないこと")

            // AppKit は表示中の窓を内部（画面登録）で保持しているため、ARC だけで確実に解放させるには
            // 先に orderOut で画面registry から外す必要がある（表示させたまま強参照を外すだけでは
            // AppKit 側の内部参照が残り、この場では決定的に解放されない）。isVisible=false にも
            // なるが、この場面で検証したいのは「弱参照が nil になる（released）」経路であり、
            // 直後の解放そのものが本題。
            window!.orderOut(nil)
            window = nil   // 唯一の強参照を手放す → このスコープの終わりで確実に解放される
        }

        #expect(!tracker.isTransitioning, "解放された窓のエントリはプルーニングで取り除かれること")
        #expect(fired, "プルーニングで空になった時点で保留ハンドラが発火すること")
    }

    /// G54-S3e ハードニング: `orderOut` は `willCloseNotification` を発火しない（閉じたのではなく
    /// 隠しただけ）ので、通知だけに頼るこのトラッカーが「順序から外された＝もう遷移中とは扱えない」を
    /// 検出できるのは `isVisible` を見るクエリ時プルーニングだけ。窓自体は解放しない
    /// （解放によるプルーニングとは別の経路を検証するため）。
    @Test("順序から外された（isVisible=false）窓の遷移エントリはプルーニングで消える")
    func prunesTransitioningWindowThatIsOrderedOut() {
        let tracker = FullScreenTransitionTracker()
        let window = makeTrackerTestWindow()
        window.orderFrontRegardless()

        tracker.testBeginTransition(window: window)
        #expect(tracker.isTransitioning, "表示中の窓を begin した直後は遷移中であること")

        window.orderOut(nil)   // close() ではないので willCloseNotification は来ない
        #expect(!tracker.isTransitioning, "isVisible=false になった窓のエントリはプルーニングで取り除かれること")
    }
}
