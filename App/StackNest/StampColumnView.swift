// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Stamp pane の 1 列（1 StampField 分）。
/// ヘッダ + [消去] chip + 値 chip 群 + [+ 新規追加] chip。
/// 4.2c-6a: value＋closure 注入の presentation-only に汎用化（ローカル=AppState / リモート=RemoteLibraryState 由来で配線）。
/// 値 chip の右クリックで定義削除（管理）。
struct StampColumnView: View {
    let field: StampField
    let label: String
    /// ソート済み表示リスト（チップ候補値）。
    let definitions: [String]
    /// 選択本が 1 件以上か（適用/消去の有効化）。
    let applyEnabled: Bool
    let onApplyValue: (String) -> Void
    let onApplyClear: () -> Void
    let onAddDefinition: (String) -> Void
    let onDeleteDefinition: (String) -> Void

    @State private var showAddPopover = false
    @State private var newValueText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.bold())
                .padding(.horizontal, 6)
                .padding(.top, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ChipView(variant: .clear, disabled: !applyEnabled) { onApplyClear() }
                    ForEach(definitions, id: \.self) { v in
                        ChipView(variant: .value(v), disabled: !applyEnabled) { onApplyValue(v) }
                            .contextMenu {
                                Button("削除", role: .destructive) { onDeleteDefinition(v) }
                            }
                    }
                    // [+ 新規追加] は定義を追加するのみ（book を変更しないので 0 件選択時でも常時有効）。
                    ChipView(variant: .newAdd, disabled: false) { showAddPopover = true }
                        .popover(isPresented: $showAddPopover) { addPopover }
                }
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新しい \(label) を追加").font(.caption.bold())
            TextField("", text: $newValueText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitAdd() }
            HStack {
                Button("キャンセル") { newValueText = ""; showAddPopover = false }
                Spacer()
                Button("追加") { commitAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newValueText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func commitAdd() {
        let trimmed = newValueText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAddDefinition(trimmed)
        newValueText = ""
        showAddPopover = false
    }
}
