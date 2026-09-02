// SPDX-License-Identifier: MIT
import SwiftUI
import CoreGraphics
import AppCore

/// G46: `BookGridCellShell` が表示する表紙の状態。
/// トップレベルに置く理由: generic 構造体のネスト型（`BookGridCellShell<...>.Cover`）にすると、
/// 後続 Task（リモート側）が generic 越しに参照する羽目になり読みにくいため（controller 判断）。
enum BookGridCover: Equatable {
    case image(CGImage)
    /// リモートだけが使う（実際に待ち時間がある）。ローカルは `.none` を渡す。
    case loading
    case none
}

/// G46: ローカル `BookCell` とリモート `RemoteBookCell` が共有する「殻」。
/// 見た目をここ 1 本に書く（2 箇所に書くと食い違う —— G47 で判断と実行を 1 本にしたのと同じ理由）。
///
/// 決定（spec §2）:
/// - 表紙の枠は **2:3 固定**、画像は fit・角丸で切り抜き・影あり
/// - タイトルは `lineLimit(2, reservesSpace: true)`・中央
/// - 著者は常に行を確保（`gridAuthorLine` ＋ `reservesSpace`）
/// - 左上ハート・右下の未読緑丸（未読のときだけ・表示のみ）
/// - リモート固有の重ね物（DL 済み印＝右上・DL 進捗＝中央）は呼び出し側から差し込む
/// - `selectionStroke`（controller 判断）: true のとき表紙の枠に選択枠線を重ねる。
///   リモートのセルは従来から表紙枠に選択の枠線を描いており、殻の中で表紙枠にぴったり描くほうが確実。
///   ローカルは既定 false のまま。
struct BookGridCellShell<TopTrailing: View, Center: View>: View {
    let cover: BookGridCover
    let title: String
    let author: String?
    let favorited: Bool
    let unseen: Bool
    let selectionStroke: Bool
    @ViewBuilder let topTrailing: () -> TopTrailing
    @ViewBuilder let center: () -> Center

    init(cover: BookGridCover, title: String, author: String?, favorited: Bool, unseen: Bool,
         selectionStroke: Bool = false,
         @ViewBuilder topTrailing: @escaping () -> TopTrailing = { EmptyView() },
         @ViewBuilder center: @escaping () -> Center = { EmptyView() }) {
        self.cover = cover
        self.title = title
        self.author = author
        self.favorited = favorited
        self.unseen = unseen
        self.selectionStroke = selectionStroke
        self.topTrailing = topTrailing
        self.center = center
    }

    private var badges: GridCellBadges { GridCellBadges.derive(favorited: favorited, unseen: unseen) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                switch cover {
                case .image(let cg):
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                case .loading:
                    ProgressView().controlSize(.small)
                case .none:
                    // 詳細ペインと同じ SF Symbol。大きさはセル幅に追従させる（gridItemSize のスライダー対応）。
                    Image(systemName: "book.closed")
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .shadow(radius: 2, y: 1)
            .overlay {
                if selectionStroke {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .topLeading) {
                if badges.showFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help("お気に入り")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // G45: リストの unseen 列（UnseenIndicator）と同じ色・記号。表示のみ（切替は右クリック）。
                if badges.showUnseen {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.green)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help("未読")
                        .accessibilityLabel(Text("未読"))
                }
            }
            .overlay(alignment: .topTrailing) { topTrailing() }
            .overlay { center() }

            // smoke v2 自由記載: 1 行の本だけセルが低くなると LazyVGrid が縦中央寄せしてずれる。常に 2 行分を確保。
            Text(title)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            // 著者も同じ理由で行を確保する（無い本だけ低くならないように）。
            Text(gridAuthorLine(author))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}
