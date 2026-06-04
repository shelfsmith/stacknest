// SPDX-License-Identifier: MIT
import SwiftUI

struct ViewerHelpOverlayView: View {
    static let rows: [(action: String, keys: String)] = [
        ("ページ送り / 戻し", "Space ↓ / ⇧Space ↑ ・ ← / →（左右ゾーンクリック）"),
        ("先頭 / 末尾", "Home / End"),
        ("ズーム / フィット", "+ - / =  (ピンチ・ドラッグでパン)"),
        ("位置ジャンプ", "0〜9  (0=先頭 / 5=50% / 9=90%)"),
        ("ページスキップ", "Tab / ⇧Tab  (設定のページ数分)"),
        ("見開き ON/OFF", "d"),
        ("表紙オフセット", "P"),
        ("横長レイアウト巡回", "w"),
        ("スライドショー 開始/停止", "s"),
        ("前の巻 / 次の巻", "[ / ]"),
        ("巻末挙動 切替", "e"),
        ("ページ方向 切替（この本）", "r"),
        ("全画面", "⌃⌘F"),
        ("閉じる", "Esc / ⌘W"),
        ("このヘルプ", "? / h"),
    ]
    var isVisible: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("キー操作").font(.system(size: 13, weight: .bold))
            ForEach(Self.rows, id: \.action) { row in
                HStack(spacing: 12) {
                    // Phase 2.6b-2 T-U1/v7: 220 → 460 に拡幅 + lineLimit(1)（結合ショートカット行の折り返し完全防止）
                    Text(row.keys).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 460, alignment: .leading)
                        .lineLimit(1)
                    Text(row.action).font(.system(size: 12))
                }
            }
        }
        .padding(18)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
    }
}
