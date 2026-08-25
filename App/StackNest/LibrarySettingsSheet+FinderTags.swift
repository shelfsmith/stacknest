// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

// Phase G39 Task 7: 庫ごとの「Finder タグと同期する項目」設定。
//
// **即時反映にしてある**（「保存」を待たない）。同じシートの「自動追加」節（`+Watch`）と同じ流儀で、
// 選択の副作用（前回同期値の全消し）が DB に走るため、ステージして後でまとめて適用すると
// 「キャンセルしたのに全消しだけ残った」という状態を作りやすい。
extension LibrarySettingsSheet {

    /// Picker の `tag` に使う「同期しない」の値。空文字は `FinderTagSyncSetting.normalize` が
    /// nil に落とすので、そのまま `setFinderTagSyncField` へ渡せる。
    static let finderTagSyncNoneTag = ""

    @ViewBuilder
    func finderTagSection() -> some View {
        GroupBox("Finder タグ") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("同期する項目").frame(width: 120, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { finderTagField },
                        set: { newValue in
                            guard newValue != finderTagField else { return }
                            finderTagField = newValue
                            // ★ 項目を変えたら前回同期値を全消しする（`setFinderTagSyncField` の中）。
                            // 残したままだと、別項目の値を「前回のタグ」と誤認して大量に消しかねない。
                            // 走行中の同期が止まるのを待つので `async`。**UI は待たせない** ——
                            // `finderTagField`（上の行）は先に更新済みなので Picker は即座に動く。
                            Task { @MainActor in
                                await appState?.setFinderTagSyncField(newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )) {
                        Text("同期しない").tag(Self.finderTagSyncNoneTag)
                        Divider()
                        ForEach(BrowserPaneState.BrowseField.allCases, id: \.self) { field in
                            Text(settings.browseLabel(for: field)).tag(field.sqlColumn)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    // Picker は `.disabled` だけで意図が伝わる（`.opacity` は手組みの行にだけ併用する）。
                    .disabled(appState?.database == nil)
                }

                HStack {
                    Button("今すぐ再照合") { appState?.startFinderTagSync(trigger: .manual) }
                        .disabled(!(appState?.canStartFinderTagSync ?? false))
                    if appState?.isFinderTagSyncRunning == true {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                Text("選んだ項目と macOS の Finder タグを双方向に同期します（庫を開いたときと、この「今すぐ再照合」のときだけ）。どちらかで消したタグはもう一方からも消えます。タグの色はそのまま保たれますが、名前に「, 」を含むタグは（区切り文字と衝突するため）同期対象から外れます。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Finder で付けたタグの取り込みには Spotlight 索引が必要です。索引が無効なボリュームでは、書き戻し（StackNest → Finder）だけが動きます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }
}
