// SPDX-License-Identifier: MIT
import SwiftUI

/// "最近の項目" の対象日数を編集する小さなシート（FX2 A9-UI）。
/// Stackroom 互換の Date-Added(within N days) スコープの N を編集する。
struct RecentDaysEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftDays: Int
    let onSave: (Int) -> Void

    /// 入力可能な日数レンジ（1 日〜約 10 年）。
    private let range = 1...3650

    init(initialDays: Int, onSave: @escaping (Int) -> Void) {
        _draftDays = State(initialValue: min(max(initialDays, 1), 3650))
        self.onSave = onSave
    }

    private var canSave: Bool {
        range.contains(draftDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近の項目").font(.headline)
            HStack {
                Text("過去")
                TextField("日数", value: $draftDays, format: .number)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $draftDays, in: range)
                    .labelsHidden()
                Text("日以内に追加した書籍を表示")
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    onSave(min(max(draftDays, 1), 3650))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
