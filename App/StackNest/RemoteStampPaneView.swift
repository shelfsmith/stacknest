// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 4.2c-6a: リモートのスタンプペイン。汎用 StampColumnView を RemoteLibraryState 由来の
/// クロージャ（サーバ定義キャッシュ / サーバ一括スタンプ API / 定義 PUT）で配線する。
/// ラベルは同期対象外のため正準ラベル（StampField.localizedTitle）を使う。
struct RemoteStampPaneView: View {
    @Bindable var state: RemoteLibraryState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(StampField.allCases.enumerated()), id: \.element) { index, field in
                StampColumnView(
                    field: field,
                    label: field.localizedTitle,
                    definitions: (state.stampDefinitions[field.dbColumn] ?? []).sorted(),
                    applyEnabled: state.canEditServer && !state.multiSelection.isEmpty,
                    onApplyValue: { state.applyStamp(field: field, value: $0) },
                    onApplyClear: { state.clearStamp(field: field) },
                    onAddDefinition: { state.addStampDefinition(field: field, value: $0) },
                    onDeleteDefinition: { state.deleteStampDefinition(field: field, value: $0) }
                )
                .frame(maxWidth: .infinity)
                if index < StampField.allCases.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: 200)
    }
}
