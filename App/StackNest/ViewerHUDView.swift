// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// ミニマル HUD: 下端に「現在 / 総数」と細い進捗バー。表示/非表示は controller が isVisible で制御。
/// noteText が非 nil のとき、進捗バー上方に独立した目立つ浮遊ラベルを表示する（~3s 自動消去、
/// updateHUD による progress 更新でノートが消えないように別チャネルで管理する）。
/// pageDirection が .rightToLeft のとき、進捗バーは右から左方向に伸びる（RTL 漫画対応）。
struct ViewerHUDView: View {
    let progressText: String
    let progressFraction: Double
    let isVisible: Bool
    /// 読み進む方向。RTL のとき進捗バーを右端から左へ伸ばす。
    var pageDirection: PageDirection = .rightToLeft
    /// 一時メモ（巻ナビ結果・レイアウトモード等）。nil のとき非表示。progress とは独立して更新される。
    var noteText: String? = nil
    /// G3b: L2 キャッシュ済みページのカバレッジ帯（0..1 割合の範囲）。リモート閲覧時のみ非空。
    var cachedSegments: [ClosedRange<Double>] = []

    var body: some View {
        VStack {
            Spacer()
            // ノートラベル: progress バー下地とは別レイヤーで中央上方に浮遊させる
            if let note = noteText {
                Text(note)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 72)   // progress バー下地（高さ56）より上方に配置
                    .transition(.opacity)
            }
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 56)
                HStack {
                    Text(progressText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 14)
                        .padding(.bottom, 8)
                    Spacer()
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let rtl = pageDirection == .rightToLeft
                    ZStack(alignment: .leading) {
                        // トラック（下地）
                        Rectangle().fill(.white.opacity(0.15))
                        // G3b: L2 キャッシュ済みカバレッジ帯（読書位置塗りより下・控えめな別色）。
                        ForEach(cachedSegments.indices, id: \.self) { i in
                            let seg = cachedSegments[i]
                            let bw = max(0, w * (seg.upperBound - seg.lowerBound))
                            let x = rtl ? w * (1 - seg.upperBound) : w * seg.lowerBound
                            Rectangle().fill(.white.opacity(0.32))
                                .frame(width: bw)
                                .offset(x: x)
                        }
                        // 読書位置の塗り（RTL は右端から）
                        let fw = w * progressFraction
                        Rectangle().fill(Color(red: 0.36, green: 0.62, blue: 0.85))
                            .frame(width: fw)
                            .offset(x: rtl ? w - fw : 0)
                    }
                    .frame(height: 3)
                    .clipped()
                }
                .frame(height: 3)
            }
        }
        .allowsHitTesting(false)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }
}
