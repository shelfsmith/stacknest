// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore
import AppCore

/// ページ方向ピッカー（2 状態: 右→左 / 左→右）。
///
/// EFFECTIVE direction = book.pageDirection ?? ViewerSettings.shared.pageDirection を表示する。
/// nil（既定に従う）は UI に露出しない。トグルは常に EXPLICIT な値 (.rightToLeft / .leftToRight)
/// を書き込む（nil を返さない）。DB の nullable は維持し、本ごと設定のない本がグローバルを
/// 継承する挙動は変えない（clearPageDirection は UI 未使用のまま残す）。
///
/// - `state`: MixedValueState<PageDirection?> — 選択中の本の book.pageDirection を集約。
///   nil が混在する場合（per-book 未設定 ↔ 設定済み混在）は .mixed として扱う。
///   表示にはグローバル設定を fold して effective direction を決定する。
/// - `onCommit`: 新しい方向を受け取るコールバック。常に non-nil を渡す。
struct PageDirectionPicker: View {
    let state: MixedValueState<PageDirection?>
    let onCommit: (PageDirection?) -> Void

    private struct Option {
        let value: PageDirection
        let icon: String
        let label: LocalizedStringKey
    }

    // 右→左（漫画デフォルト）= arrow.right、左→右 = arrow.left（矢印の向きで識別）
    private static let options: [Option] = [
        .init(value: .rightToLeft, icon: "arrow.right", label: "右→左"),
        .init(value: .leftToRight, icon: "arrow.left",  label: "左→右"),
    ]

    /// 現在の実効方向。nil（per-book 未設定）はグローバル設定で補完する。
    /// .mixed の場合は nil を返し、両ボタンとも非選択状態にする。
    @MainActor
    private var effectiveDirection: PageDirection? {
        switch state {
        case .unanimous(let v):
            return v ?? ViewerSettings.shared.pageDirection
        case .mixed:
            return nil
        }
    }

    var body: some View {
        // Phase 2.6b-2 T-U2: "ページ方向" を可視ラベルとして矢印の前に表示する。
        // アクセシビリティラベルは accessibilityLabel 側で保持。
        HStack(spacing: 4) {
            Text("ページ方向")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Self.options.indices, id: \.self) { idx in
                let opt = Self.options[idx]
                let selected = effectiveDirection == opt.value
                Button { onCommit(opt.value) } label: {
                    Image(systemName: opt.icon)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .font(.title3)
                        .frame(width: 24, height: 24)
                        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(opt.label))
                .accessibilityLabel(Text(opt.label))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("ページ方向"))
    }
}
