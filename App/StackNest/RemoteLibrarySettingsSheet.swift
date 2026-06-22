// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import RemoteClient

/// 4.2c-8 B1(v2): リモートから開く「ライブラリ設定」シート（RW）。ツールバーの歯車から開く。
/// 実体は接続先（ローカル）ライブラリの設定をリモートで変更する UI なので呼称は「ライブラリ設定」。
/// 現状はラベルカスタマイズのみ（ローカルと同じ LabelEditorView を再利用）。後々サーバ同期可能な
/// 設定項目が増えたら、ここに GroupBox / タブを追加していく方針。
/// 保存はサーバへ PUT → 成功で per-window settings の override を更新する。
struct RemoteLibrarySettingsSheet: View {
    let state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    @Environment(\.dismiss) private var dismiss
    @State private var stagedFieldLabels: [String: String] = [:]
    @State private var stagedBookTypeLabels: [String: String] = [:]
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ライブラリ設定").font(.title2.bold())
            ScrollView {
                // 現状はラベルのみ。将来の設定項目はこの VStack に追加する。
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
