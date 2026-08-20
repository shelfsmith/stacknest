// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Phase 2.6c: 内蔵ビューアのグローバル設定を描画する共有フォーム。
/// （項目数は増えるので数えて書かない。G40 でルーペの形と倍率が加わった）
/// SettingsView「表示」タブと FirstRunWizardView（③内蔵ビューア設定）の両方から使う。
/// 各行は `settings.useBuiltInViewer` が false のとき disabled になる（SettingsView での
/// 既存挙動を保持。ウィザードでは内蔵選択時のみ表示されるため常に enabled）。
struct BuiltInViewerSettingsForm: View {
    @Bindable var settings: ViewerSettings

    /// スライドショーの間隔 TextField の入力中表示（整数秒、最大 2 桁 = 1...60）。
    @State private var autoAdvanceIntervalInput: String = ""
    @FocusState private var autoAdvanceFieldFocused: Bool

    /// Tab スキップのページ数 TextField の入力中表示（最大 3 桁 = 1...100）。
    @State private var tabSkipPageCountInput: String = ""
    @FocusState private var tabSkipFieldFocused: Bool

    var body: some View {
        Group {
            // ページ方向（既定）
            Picker("ページ方向（既定）", selection: $settings.pageDirection) {
                Text("右 → 左（漫画）").tag(PageDirection.rightToLeft)
                Text("左 → 右").tag(PageDirection.leftToRight)
            }
            .disabled(!settings.useBuiltInViewer)

            // 見開きをデフォルトで表示（per-book 設定がない本に適用）
            Toggle("見開きを既定で表示", isOn: $settings.spreadByDefault)
                .disabled(!settings.useBuiltInViewer)

            // 全 book 共通の全画面起動設定
            Toggle("全画面で開く", isOn: $settings.openFullScreenByDefault)
                .disabled(!settings.useBuiltInViewer)

            // G15 V1: 複数ビューア窓の許可（OFF=単一ビューア維持／ON=別の本は別窓）。
            Toggle("複数ビューアの起動を許可", isOn: $settings.allowMultipleViewerWindows)
                .disabled(!settings.useBuiltInViewer)
                .help("OFF: 別の本を開くと既存のビューアを閉じて1つに保ちます。ON: 別の本は別ウィンドウで開きます。どちらでも同じ本は1つにまとまります。")

            Picker("最後のページの次", selection: $settings.endOfBookBehavior) {
                Text("停止").tag(EndOfBookBehavior.stop)
                Text("次の巻へ（同じシリーズ）").tag(EndOfBookBehavior.nextBook)
                Text("ループ").tag(EndOfBookBehavior.loop)
            }
            .disabled(!settings.useBuiltInViewer)

            HStack {
                Text("スライドショーの間隔（秒）")
                Spacer()
                TextField("", text: $autoAdvanceIntervalInput)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .lineLimit(1)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .focused($autoAdvanceFieldFocused)
                    .onChange(of: autoAdvanceIntervalInput) { _, newValue in
                        let cleaned = String(newValue.filter(\.isNumber).prefix(2))
                        if cleaned != newValue { autoAdvanceIntervalInput = cleaned }
                    }
                    .onChange(of: autoAdvanceFieldFocused) { _, focused in
                        if !focused { commitAutoAdvanceIntervalInput() }
                    }
                    .onSubmit { commitAutoAdvanceIntervalInput() }
                Stepper("", value: $settings.autoAdvanceInterval, in: 1...60, step: 1)
                    .labelsHidden()
            }
            .disabled(!settings.useBuiltInViewer)
            .opacity(settings.useBuiltInViewer ? 1.0 : 0.5)
            .onAppear { autoAdvanceIntervalInput = String(Int(settings.autoAdvanceInterval)) }
            .onChange(of: settings.autoAdvanceInterval) { _, newValue in
                let synced = String(Int(newValue))
                if autoAdvanceIntervalInput != synced { autoAdvanceIntervalInput = synced }
            }

            HStack {
                Text("Tab スキップのページ数")
                Spacer()
                TextField("", text: $tabSkipPageCountInput)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .lineLimit(1)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .focused($tabSkipFieldFocused)
                    .onChange(of: tabSkipPageCountInput) { _, newValue in
                        let cleaned = String(newValue.filter(\.isNumber).prefix(3))
                        if cleaned != newValue { tabSkipPageCountInput = cleaned }
                    }
                    .onChange(of: tabSkipFieldFocused) { _, focused in
                        if !focused { commitTabSkipPageCountInput() }
                    }
                    .onSubmit { commitTabSkipPageCountInput() }
                Stepper("", value: $settings.tabSkipPageCount, in: 1...100)
                    .labelsHidden()
            }
            .disabled(!settings.useBuiltInViewer)
            .opacity(settings.useBuiltInViewer ? 1.0 : 0.5)
            .onAppear { tabSkipPageCountInput = String(settings.tabSkipPageCount) }
            .onChange(of: settings.tabSkipPageCount) { _, newValue in
                let synced = String(newValue)
                if tabSkipPageCountInput != synced { tabSkipPageCountInput = synced }
            }

            // G40: ルーペの形（グローバル）
            Picker("ルーペの形", selection: $settings.loupeShape) {
                ForEach(LoupeShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .disabled(!settings.useBuiltInViewer)

            // G40: 倍率は本を見ながらスクロールで決めるものなので、ここでは
            // **現在値の表示と既定へ戻す手段**だけを置く（スライダーは置かない）。
            HStack {
                Text("ルーペの倍率")
                Spacer()
                Text(String(format: "%.1f×", settings.loupeMagnification))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("既定に戻す") {
                    settings.loupeMagnification = Double(LoupeMagnification.defaultValue)
                }
                .controlSize(.small)
            }
            .disabled(!settings.useBuiltInViewer)
            // 隣接する行（スライドショー間隔・Tab スキップ）と同じ作法。`.disabled` だけでは
            // `Text` のラベルが暗くならないため、既存行はいずれも opacity を併用している。
            .opacity(settings.useBuiltInViewer ? 1.0 : 0.5)
        }
    }

    private func commitAutoAdvanceIntervalInput() {
        if let v = Int(autoAdvanceIntervalInput) {
            settings.autoAdvanceInterval = Double(min(max(v, 1), 60))
        }
        autoAdvanceIntervalInput = String(Int(settings.autoAdvanceInterval))
    }

    private func commitTabSkipPageCountInput() {
        if let v = Int(tabSkipPageCountInput) {
            settings.tabSkipPageCount = min(max(v, 1), 100)
        }
        tabSkipPageCountInput = String(settings.tabSkipPageCount)
    }
}
