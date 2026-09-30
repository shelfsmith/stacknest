// SPDX-License-Identifier: MIT
import Foundation

/// G59: ホイール／トラックパッドで送る向き。
public enum WheelPageTurn: Equatable, Sendable {
    /// 縦: 次のページ／前のページ
    case forward, backward
    /// 横: 画面上で左へ／右へ（次か前かは本の綴じ方向で決まる）
    case leftward, rightward
}

extension WheelPageTurn {
    /// 画像ビューアの操作への写像。横方向は設定で切る・左右を入れ替える。
    public func viewerAction(horizontalTurnsPages: Bool, reversesHorizontal: Bool) -> ViewerAction? {
        switch self {
        case .forward: return .nextPage
        case .backward: return .previousPage
        case .leftward, .rightward:
            guard horizontalTurnsPages else { return nil }
            let towardLeft = (self == .leftward) != reversesHorizontal
            return towardLeft ? .pageLeftward : .pageRightward
        }
    }
}

/// G59: ホイール／トラックパッドのイベントを「1 ジェスチャ = 1 ページ」に量子化する。
/// 電子書籍（Washi の `EPUBReaderView.turnPageByWheel`）と同じ規則と数値にしてある
/// （作者の判断 2026-09-30「電子書籍と完全に揃える」）。変えるときは両方を揃えること。
public struct WheelPageTurnGesture: Sendable {
    /// この時間イベントが途切れたら、次のイベントは新しいジェスチャ
    static let quietPeriod: TimeInterval = 0.25
    /// 1 回送るのに要る累計の移動量
    static let threshold: Double = 50
    /// 精密でないホイール（1 ノッチ = 1 行）の換算
    static let coarseScale: Double = 40

    private var accumulator: Double = 0
    private var lastTime: TimeInterval = -.infinity
    private var latched = false
    private var horizontal = false

    public init() {}

    /// イベントを 1 つ渡す。送るなら向きを返す。
    /// - Parameters:
    ///   - deltaX, deltaY: AppKit の `scrollingDeltaX/Y`（正 = 文書の先頭方向）
    ///   - timestamp: `NSEvent.timestamp`（systemUptime 基準）
    ///   - isBusy: 巻の切り替え中など、送ってはいけない間
    public mutating func consume(deltaX: Double, deltaY: Double, hasPreciseDeltas: Bool,
                                 timestamp: TimeInterval, isBusy: Bool) -> WheelPageTurn? {
        // トラックパッドは指を置いた時点で移動量 0 のイベント(mayBegin)を送る。
        // これで軸を決めると縦になり、続く横スワイプを取りこぼす
        guard deltaX != 0 || deltaY != 0 else { return nil }
        // 忙しい間の動きは送りに使わない。手が動いていることは記録し、
        // 同じジェスチャが続く間は送らない
        guard !isBusy else {
            lastTime = timestamp
            latched = true
            return nil
        }
        if timestamp - lastTime > Self.quietPeriod {
            latched = false
            accumulator = 0
            horizontal = abs(deltaX) > abs(deltaY)
        }
        lastTime = timestamp
        guard !latched else { return nil }
        let scale = hasPreciseDeltas ? 1 : Self.coarseScale
        accumulator += scale * (horizontal ? deltaX : deltaY)
        guard abs(accumulator) >= Self.threshold else { return nil }
        let positive = accumulator > 0
        accumulator = 0
        latched = true
        if horizontal { return positive ? .leftward : .rightward }
        return positive ? .backward : .forward
    }

    /// 巻の切り替えなどを始めた時点で呼ぶ。そこから 0.25 秒静かになるまで送らない
    /// （前の巻から続く慣性で、次の巻のページを送らないため）。
    public mutating func latch(at time: TimeInterval) {
        latched = true
        lastTime = time
    }
}
