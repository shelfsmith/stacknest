// SPDX-License-Identifier: MIT
import SwiftUI

/// 4.2c-8: ラベルカスタマイズ編集 UI（ローカル設定シート / リモート編集シートで共用）。
/// settings に密結合せず、2 マップの Binding と「正準デフォルト名の行」だけを受ける純粋ビュー。
/// 空欄入力は該当キーを除去（＝既定ラベルへフォールバック）。
struct LabelEditorView: View {
    @Binding var fieldLabels: [String: String]      // key = dbColumn
    @Binding var bookTypeLabels: [String: String]   // key = "0".."5"
    /// 内容系フィールドの行（key=dbColumn, canonical=正準名）。
    let fieldRows: [(key: String, canonical: String)]
    /// bookType の行（raw=0..5, canonical=正準名）。
    let bookTypeRows: [(raw: Int, canonical: String)]

    var body: some View {
        GroupBox("ラベルのカスタマイズ") {
            VStack(alignment: .leading, spacing: 8) {
                Text("空欄にすると既定のラベルに戻ります。")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(Array(fieldRows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.canonical).frame(width: 120, alignment: .leading)
                        TextField(row.canonical, text: bindingForField(row.key))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                }

                Divider()
                Text("種類（bookType）").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(bookTypeRows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.canonical).frame(width: 120, alignment: .leading)
                        TextField(row.canonical, text: bindingForBookType(row.raw))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                }

                HStack {
                    Spacer()
                    Button("デフォルトに戻す", role: .destructive) {
                        fieldLabels = [:]
                        bookTypeLabels = [:]
                    }
                }
            }
            .padding(8)
        }
    }

    private func bindingForField(_ key: String) -> Binding<String> {
        Binding(
            get: { fieldLabels[key] ?? "" },
            set: { newVal in
                if newVal.isEmpty { fieldLabels.removeValue(forKey: key) } else { fieldLabels[key] = newVal }
            }
        )
    }

    private func bindingForBookType(_ i: Int) -> Binding<String> {
        let key = String(i)
        return Binding(
            get: { bookTypeLabels[key] ?? "" },
            set: { newVal in
                if newVal.isEmpty { bookTypeLabels.removeValue(forKey: key) } else { bookTypeLabels[key] = newVal }
            }
        )
    }
}
