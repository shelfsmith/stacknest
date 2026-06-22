// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 4.2c-8 B1: ローカルのラベル編集シート。ライブラリ設定シートのラベルタブを廃し、ツールバーの
/// tag アイコンから開く（リモート RemoteLabelEditorSheet と同じ体験）。共有 LabelEditorView を使い、
/// 保存は settings.customFieldLabels / customBookTypeLabels に直接反映（didSet で DB 永続化）。
struct LocalLabelEditorSheet: View {
    @Bindable var settings: LibrarySettings

    @Environment(\.dismiss) private var dismiss
    @State private var stagedFieldLabels: [String: String] = [:]
    @State private var stagedBookTypeLabels: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ラベルを編集").font(.title2.bold())
            ScrollView {
                LabelEditorView(
                    fieldLabels: $stagedFieldLabels,
                    bookTypeLabels: $stagedBookTypeLabels,
                    fieldRows: LibrarySettingsSheet.fieldLabelRows,
                    bookTypeRows: LibrarySettingsSheet.bookTypeLabelRows)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            stagedFieldLabels = settings.customFieldLabels
            stagedBookTypeLabels = settings.customBookTypeLabels
        }
    }

    private func save() {
        if settings.customFieldLabels != stagedFieldLabels {
            settings.customFieldLabels = stagedFieldLabels
        }
        if settings.customBookTypeLabels != stagedBookTypeLabels {
            settings.customBookTypeLabels = stagedBookTypeLabels
        }
        dismiss()
    }
}
