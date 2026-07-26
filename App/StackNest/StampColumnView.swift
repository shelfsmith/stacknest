// SPDX-License-Identifier: MIT
import SwiftUI

/// Stamp pane の 1 列（1 StampField 分）。
/// ヘッダ + [消去] chip + 値 chip 群 + [+ 新規追加] chip。
/// 4.2c-6a: value＋closure 注入の presentation-only に汎用化（ローカル=AppState / リモート=RemoteLibraryState 由来で配線）。
/// 値 chip の右クリックで定義削除（管理）。
struct StampColumnView: View {
    let label: String
    /// ソート済み表示リスト（チップ候補値）。
    let definitions: [String]
    /// 選択本が 1 件以上か（適用/消去の有効化）。
    let applyEnabled: Bool
    /// 定義の追加・削除が可能か（ローカル=常時 / リモート=RW のみ）。
    var editEnabled: Bool = true
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
                        HStack(spacing: 2) {
                            ChipView(variant: .value(v), disabled: !applyEnabled) { onApplyValue(v) }
                            // D2: チップ右に × を設けて定義を削除（右クリックでも可）。
                            Button { onDeleteDefinition(v) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!editEnabled)
                            .opacity(editEnabled ? 1.0 : 0.3)
                            .help("この値（定義）を削除")
                        }
                        .contextMenu {
                            Button("削除", role: .destructive) { onDeleteDefinition(v) }
                                .disabled(!editEnabled)
                        }
                    }
                    // [+ 新規追加] は定義を追加するのみ（book を変更しないので 0 件選択時でも有効。
                    // ただし編集不可（リモート R）のときは無効）。
                    ChipView(variant: .newAdd, disabled: !editEnabled) { showAddPopover = true }
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
