// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter

/// G54-S3: 1 回のページ送りに掛ける演出。
public struct PageTurnPlan: Equatable, Sendable {
    /// `.fade` か `.slide`（`.off` の計画は作らない）。
    public let style: PageTurnStyleValue
    /// スライドで旧ページを右へ抜くか（false なら左へ）。フェードでは使わない。
    public let slideTowardRight: Bool

    public init(style: PageTurnStyleValue, slideTowardRight: Bool) {
        self.style = style
        self.slideTowardRight = slideTowardRight
    }
}

/// G54-S3: 画像ビューアのページ送りに演出を掛けるかを決める。条件と向きは Washi
/// （`EPUBReaderView.turnInDocAnimated` と `animatePageTurn`）に揃え、両ビューアで見え方を同じにする。
/// **隣への送り（goNext / goPrev）からだけ呼ぶ。** ジャンプ系は呼ばないことで対象外にする。
public enum PageTurnDecision {
    /// これ以下の間隔の連続送り（キーの押しっぱなし）には演出を掛けない。
    public static let minimumInterval: TimeInterval = 0.3
    /// 演出の長さ。
    public static let duration: TimeInterval = 0.22

    public static func plan(style: PageTurnStyleValue, reduceMotion: Bool, secondsSinceLastTurn: TimeInterval,
                            forward: Bool, rightToLeft: Bool) -> PageTurnPlan? {
        guard style != .off, !reduceMotion, secondsSinceLastTurn > minimumInterval else { return nil }
        // Washi: direction = (forward ? 1 : -1) * (isRTL ? 1 : -1)。正なら右へ。
        return PageTurnPlan(style: style, slideTowardRight: forward == rightToLeft)
    }
}
