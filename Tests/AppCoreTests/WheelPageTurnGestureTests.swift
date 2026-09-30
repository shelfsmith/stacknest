// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G59: ホイール／トラックパッドの「1 ジェスチャ = 1 ページ」の判定。Washi の
/// `turnPageByWheel` と同じ規則と数値（電子書籍と完全に揃える・作者の判断 2026-09-30）。
@Suite("G59: ホイールでのページ送りの判定")
struct WheelPageTurnGestureTests {
    /// 精密なイベント(トラックパッド・なめらかなマウス)を 16ms 間隔で n 個
    private func swipe(_ g: inout WheelPageTurnGesture, dx: Double = 0, dy: Double = 0,
                       count: Int = 10, start: TimeInterval, busy: Bool = false) -> [WheelPageTurn] {
        (0..<count).compactMap { i in
            g.consume(deltaX: dx, deltaY: dy, hasPreciseDeltas: true,
                      timestamp: start + Double(i) * 0.016, isBusy: busy)
        }
    }

    @Test func oneGestureTurnsOnce() {
        var g = WheelPageTurnGesture()
        #expect(swipe(&g, dy: -12, start: 100) == [.forward], "累計 50 で 1 回、残りは同じジェスチャ")
    }

    @Test func momentumWithinQuietPeriodDoesNotTurnAgain() {
        var g = WheelPageTurnGesture()
        _ = swipe(&g, dy: -12, count: 10, start: 100)
        // 0.2 秒あけて続く(慣性) → 同じジェスチャのまま
        #expect(swipe(&g, dy: -12, count: 10, start: 100 + 0.16 + 0.2).isEmpty)
    }

    @Test func pauseLongerThanQuietPeriodStartsNewGesture() {
        var g = WheelPageTurnGesture()
        _ = swipe(&g, dy: -12, start: 100)
        #expect(swipe(&g, dy: -12, start: 100 + 0.16 + 0.3) == [.forward])
    }

    @Test func directionSigns() {
        var g = WheelPageTurnGesture()
        #expect(swipe(&g, dy: 12, start: 100) == [.backward], "縦: 正 = 文書の先頭方向 = 前へ")
        #expect(swipe(&g, dx: 12, start: 101) == [.leftward], "横: 正 = 左へ")
        #expect(swipe(&g, dx: -12, start: 102) == [.rightward])
        #expect(swipe(&g, dy: -12, start: 103) == [.forward])
    }

    @Test func axisIsChosenByFirstMovingEvent() {
        var g = WheelPageTurnGesture()
        // 縦寄りで始まったジェスチャは、途中で横が大きくなっても縦のまま
        #expect(g.consume(deltaX: 1, deltaY: -3, hasPreciseDeltas: true, timestamp: 100, isBusy: false) == nil)
        #expect(swipe(&g, dx: -30, dy: -6, count: 9, start: 100.016) == [.forward])
    }

    @Test func zeroDeltaEventDoesNotChooseTheAxis() {
        var g = WheelPageTurnGesture()
        // トラックパッドの mayBegin(移動量 0)の後に横スワイプ
        #expect(g.consume(deltaX: 0, deltaY: 0, hasPreciseDeltas: true, timestamp: 100, isBusy: false) == nil)
        #expect(swipe(&g, dx: -12, start: 100.03) == [.rightward])
    }

    @Test func coarseWheelNeedsTwoNotches() {
        var g = WheelPageTurnGesture()
        // 精密でないホイールは 1 ノッチ = 40(閾値 50 に届かない)
        #expect(g.consume(deltaX: 0, deltaY: -1, hasPreciseDeltas: false, timestamp: 100, isBusy: false) == nil)
        #expect(g.consume(deltaX: 0, deltaY: -1, hasPreciseDeltas: false, timestamp: 100.06, isBusy: false) == .forward)
        // ゆっくり 1 ノッチずつ(0.25 秒超)では送られない(電子書籍と同じ)
        var slow = WheelPageTurnGesture()
        for i in 0..<5 {
            #expect(slow.consume(deltaX: 0, deltaY: -1, hasPreciseDeltas: false,
                                 timestamp: 200 + Double(i), isBusy: false) == nil)
        }
    }

    @Test func busyEventsDoNotTurnAndKeepTheLatch() {
        var g = WheelPageTurnGesture()
        #expect(swipe(&g, dy: -12, count: 10, start: 100, busy: true).isEmpty, "忙しい間は送らない")
        // 忙しさが終わっても、同じ手の動き(0.25 秒以内に続く)では送らない
        #expect(swipe(&g, dy: -12, count: 10, start: 100.16).isEmpty)
        #expect(swipe(&g, dy: -12, start: 100.32 + 0.3) == [.forward], "止めてからなら送る")
    }

    @Test func latchBlocksUntilQuiet() {
        var g = WheelPageTurnGesture()
        g.latch(at: 100)
        #expect(swipe(&g, dy: -12, count: 10, start: 100.05).isEmpty, "ラッチから 0.25 秒以内に始まった動きでは送らない")
        #expect(swipe(&g, dy: -12, start: 100.21 + 0.3) == [.forward])
    }

    @Test func viewerActionMapping() {
        #expect(WheelPageTurn.forward.viewerAction(horizontalTurnsPages: false, reversesHorizontal: true) == .nextPage)
        #expect(WheelPageTurn.backward.viewerAction(horizontalTurnsPages: false, reversesHorizontal: false) == .previousPage)
        #expect(WheelPageTurn.leftward.viewerAction(horizontalTurnsPages: true, reversesHorizontal: false) == .pageLeftward)
        #expect(WheelPageTurn.rightward.viewerAction(horizontalTurnsPages: true, reversesHorizontal: false) == .pageRightward)
        #expect(WheelPageTurn.leftward.viewerAction(horizontalTurnsPages: true, reversesHorizontal: true) == .pageRightward)
        #expect(WheelPageTurn.rightward.viewerAction(horizontalTurnsPages: true, reversesHorizontal: true) == .pageLeftward)
        #expect(WheelPageTurn.leftward.viewerAction(horizontalTurnsPages: false, reversesHorizontal: false) == nil)
    }
}
