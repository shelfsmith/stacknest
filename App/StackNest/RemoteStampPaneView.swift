// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 4.2c-6a: リモートのスタンプペイン。汎用 StampColumnView を RemoteLibraryState 由来の
/// クロージャ（サーバ定義キャッシュ / サーバ一括スタンプ API / 定義 PUT）で配線する。
/// 4.2c-8: フィールドラベルはサーバ同期ラベル（settings.stampLabel）を使い、ローカルと同等化。
struct RemoteStampPaneView: View {
    @Bindable var state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(StampField.allCases.enumerated()), id: \.element) { index, field in
                StampColumnView(
                    field: field,
                    label: settings.stampLabel(for: field),
                    definitions: (state.stampDefinitions[field.dbColumn] ?? []).sorted(),
                    applyEnabled: state.canEdit && !state.multiSelection.isEmpty,
                    editEnabled: state.canEdit,
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
        // C2 改善: スタンプペイン表示時にサーバ定義を再取得（タブ切替で最新化＝再接続不要）。
        .task { await state.loadStampDefinitions() }
    }
}
