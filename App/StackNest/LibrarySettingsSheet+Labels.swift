// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

extension LibrarySettingsSheet {
    @ViewBuilder
    func labelSection() -> some View {
        GroupBox("ラベルのカスタマイズ") {
            VStack(alignment: .leading, spacing: 8) {
                Text("空欄にすると既定のラベルに戻ります。")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(Array(fieldLabelRows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.defaultLabel).frame(width: 120, alignment: .leading)
                        TextField(row.defaultLabel, text: bindingForField(row.key))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                }

                Divider()
                Text("種類（bookType）").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { i in
                    HStack {
                        Text(BookTypeLabel.canonicalLabel(for: i)).frame(width: 120, alignment: .leading)
                        TextField(BookTypeLabel.canonicalLabel(for: i), text: bindingForBookType(i))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                }

                HStack {
                    Spacer()
                    Button("デフォルトに戻す", role: .destructive) {
                        stagedFieldLabels = [:]
                        stagedBookTypeLabels = [:]
                    }
                }
            }
            .padding(8)
        }
    }

    /// 内容系 5 フィールドの行（key=dbColumn, defaultLabel=正準）。
    /// 既定ラベルは StampField を単一ソースにする（5 内容フィールドを全て持ち、
    /// keyword_c も含む。BookColumn と同一表記に統一済み）。
    private var fieldLabelRows: [(key: String, defaultLabel: String)] {
        StampField.allCases.map { (key: $0.dbColumn, defaultLabel: $0.localizedTitle) }
    }

    private func bindingForField(_ key: String) -> Binding<String> {
        Binding(
            get: { stagedFieldLabels[key] ?? "" },
            set: { newVal in
                if newVal.isEmpty { stagedFieldLabels.removeValue(forKey: key) } else { stagedFieldLabels[key] = newVal }
            }
        )
    }

    private func bindingForBookType(_ i: Int) -> Binding<String> {
        let key = String(i)
        return Binding(
            get: { stagedBookTypeLabels[key] ?? "" },
            set: { newVal in
                if newVal.isEmpty { stagedBookTypeLabels.removeValue(forKey: key) } else { stagedBookTypeLabels[key] = newVal }
            }
        )
    }
}
