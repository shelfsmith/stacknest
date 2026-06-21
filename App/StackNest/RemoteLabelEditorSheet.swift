// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import RemoteClient

/// 4.2c-8: リモート（RW）のラベル編集シート。ローカルと同じ LabelEditorView を再利用し、
/// 保存はサーバへ PUT → 成功で per-window settings の override を更新する。
struct RemoteLabelEditorSheet: View {
    let state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    @Environment(\.dismiss) private var dismiss
    @State private var stagedFieldLabels: [String: String] = [:]
    @State private var stagedBookTypeLabels: [String: String] = [:]
    @State private var errorText: String?
    @State private var saving = false

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
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            stagedFieldLabels = settings.remoteFieldLabelOverride ?? [:]
            stagedBookTypeLabels = settings.remoteBookTypeLabelOverride ?? [:]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let saved = try await state.saveLabels(
                customFieldLabels: stagedFieldLabels, customBookTypeLabels: stagedBookTypeLabels)
            settings.remoteFieldLabelOverride = saved.customFieldLabels
            settings.remoteBookTypeLabelOverride = saved.customBookTypeLabels
            dismiss()
        } catch {
            if case RemoteClientError.forbidden = error { errorText = "編集権限がありません" }
            else { errorText = "ラベルの更新に失敗しました" }
        }
    }
}
