// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore
import EPUBAdapter

/// G57: 内蔵ビューアの設定のうち、画像ビューアだけに効くもの（「画像ビューア」の節）。
/// 設定の窓（内蔵ビューアのタブ）と初回ウィザードの両方から、見出し付きの Section の中身として使う。
struct ImageViewerSettingsForm: View {
    @Bindable var settings: ViewerSettings

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

            // 見開きをデフォルトで表示（per-book 設定がない本に適用）
            Toggle("見開きを既定で表示", isOn: $settings.spreadByDefault)

            // 全 book 共通の全画面起動設定（電子書籍ビューアは別設定・G51）。見出しで対象が分かるので
            // 項目名は電子書籍の節と同じ「全画面で開く」（G57）。
            Toggle("全画面で開く", isOn: $settings.openFullScreenByDefault)

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

            // G40: ルーペの大きさ（グローバル）
            Picker("ルーペの大きさ", selection: $settings.loupeSize) {
                ForEach(LoupeSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }

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
        }
    }

    private func commitTabSkipPageCountInput() {
        if let v = Int(tabSkipPageCountInput) {
            settings.tabSkipPageCount = min(max(v, 1), 100)
        }
        tabSkipPageCountInput = String(settings.tabSkipPageCount)
    }
}
