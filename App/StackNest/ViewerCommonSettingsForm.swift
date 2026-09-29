// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore
import EPUBAdapter

/// G57: 内蔵ビューアの設定のうち、画像ビューアと電子書籍ビューアの両方に効くもの（「ビューア共通」の節）。
/// 設定の窓（内蔵ビューアのタブ）と初回ウィザードの両方から、見出し付きの Section の中身として使う。
/// 各行は**常に有効**（リモート閲覧は外部ビューアの設定に関わらず内蔵ビューアで表示されるため・G54-S2）。
struct ViewerCommonSettingsForm: View {
    @Bindable var settings: ViewerSettings

    /// スライドショーの間隔 TextField の入力中表示（整数秒、最大 2 桁 = 1...60）。
    @State private var autoAdvanceIntervalInput: String = ""
    @FocusState private var autoAdvanceFieldFocused: Bool

    /// Tab スキップのページ数 TextField の入力中表示（最大 3 桁 = 1...100）。
    @State private var tabSkipPageCountInput: String = ""
    @FocusState private var tabSkipFieldFocused: Bool

    var body: some View {
        Group {
            // G54-S3: ページ送りの演出（画像ビューアと電子書籍ビューアの両方に効く）。
            Picker("ページ送りの演出", selection: $settings.pageTurnStyle) {
                Text("なし").tag(PageTurnStyleValue.off)
                Text("フェード").tag(PageTurnStyleValue.fade)
                Text("スライド").tag(PageTurnStyleValue.slide)
            }
            .help("画像ビューアと電子書籍ビューアの両方に効きます。キーを押し続けたときと「視差効果を減らす」が有効なときは省きます。")

            // G15 V1: 複数ビューア窓の許可（OFF=単一ビューア維持／ON=別の本は別窓）。
            Toggle("複数ビューアの起動を許可", isOn: $settings.allowMultipleViewerWindows)
                .help("OFF: 別の本を開くと既存のビューアを閉じて1つに保ちます。ON: 別の本は別ウィンドウで開きます。どちらでも同じ本は1つにまとまります。")

            // 見開きを既定で表示。画像は本ごとの設定が無い本に、電子書籍は開くたびに適用（G57 で共通へ移した）。
            Toggle("見開きを既定で表示", isOn: $settings.spreadByDefault)

            // Tab／⇧Tab で飛ぶページ数。電子書籍は本全体のページで数える（G57 で共通へ移した）。
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

            Picker("最後のページの次", selection: $settings.endOfBookBehavior) {
                Text("停止").tag(EndOfBookBehavior.stop)
                Text("次の巻へ（同じシリーズ）").tag(EndOfBookBehavior.nextBook)
                Text("ループ").tag(EndOfBookBehavior.loop)
            }

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
            .onAppear { autoAdvanceIntervalInput = String(Int(settings.autoAdvanceInterval)) }
            .onChange(of: settings.autoAdvanceInterval) { _, newValue in
                let synced = String(Int(newValue))
                if autoAdvanceIntervalInput != synced { autoAdvanceIntervalInput = synced }
            }
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
