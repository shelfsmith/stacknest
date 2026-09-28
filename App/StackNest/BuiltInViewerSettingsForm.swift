// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore
import EPUBAdapter

/// Phase 2.6c: 内蔵ビューアのグローバル設定を描画する共有フォーム。
/// （項目数は増えるので数えて書かない。G40 でルーペの形・倍率・大きさが加わった）
/// SettingsView「表示」タブと FirstRunWizardView（③内蔵ビューア設定）の両方から使う。
/// 各行は**常に有効**。リモート閲覧は外部ビューアの設定に関わらず常に内蔵ビューアで表示されるため、
/// 画像も EPUB も外部にしていても内蔵ビューアの設定は使われ続ける（使われている設定を灰色にしない）。
/// G54-S2 の smoke で、リモート閲覧で外部ビューアが使えるようになって初めて無効化を検討する、と決めた。
struct BuiltInViewerSettingsForm: View {
    @Bindable var settings: ViewerSettings

    /// スライドショーの間隔 TextField の入力中表示（整数秒、最大 2 桁 = 1...60）。
    @State private var autoAdvanceIntervalInput: String = ""
    @FocusState private var autoAdvanceFieldFocused: Bool

    /// Tab スキップのページ数 TextField の入力中表示（最大 3 桁 = 1...100）。
    @State private var tabSkipPageCountInput: String = ""
    @FocusState private var tabSkipFieldFocused: Bool

    /// G56-S3: EPUB の書体候補（機械に入っているものだけ）。フォームが現れたときに 1 回だけ求める
    /// （View の init や body の評価のたびに NSFontManager へ問い合わせない）。
    @State private var fontCandidates: [EPUBFontCandidate] = []

    /// 保存値が候補に無いときは「本の指定に従う」（nil）に見せる。保存値そのものは消さない。
    /// 判定は求めておいた候補の集合で行う（Picker の tag も候補だけなので、これと一致させる）。
    private var fontSelection: Binding<String?> {
        let families = Set(fontCandidates.map(\.family))
        return Binding(get: { EPUBFontCandidates.effectiveFamily(settings.epubJapaneseFontFamily, installed: families) },
                       set: { settings.epubJapaneseFontFamily = $0 })
    }

    var body: some View {
        Group {
            // ページ方向（既定）
            Picker("ページ方向（既定）", selection: $settings.pageDirection) {
                Text("右 → 左（漫画）").tag(PageDirection.rightToLeft)
                Text("左 → 右").tag(PageDirection.leftToRight)
            }

            // 見開きをデフォルトで表示（per-book 設定がない本に適用）
            Toggle("見開きを既定で表示", isOn: $settings.spreadByDefault)

            // 全 book 共通の全画面起動設定
            Toggle("全画面で開く（画像）", isOn: $settings.openFullScreenByDefault)

            // G51（Q3=C-2）: EPUB の窓は別設定（行長が伸びると読みにくいので使い分けたい）。
            Toggle("全画面で開く（EPUB）", isOn: $settings.openEPUBFullScreenByDefault)

            // G54-S2b: EPUB の配色。既定はシステムの外観に従う。
            Picker("EPUB の配色", selection: $settings.epubTheme) {
                Text("システムに合わせる").tag(EPUBReaderThemeValue.system)
                Text("ライト").tag(EPUBReaderThemeValue.light)
                Text("ダーク").tag(EPUBReaderThemeValue.dark)
            }

            // G56-S3: 書体（機械にある候補だけ）。保存値が機械に無いときは「本の指定」に見せる（保存値は残す）。
            Picker("EPUB の書体", selection: fontSelection) {
                Text("本の指定に従う").tag(String?.none)
                ForEach(fontCandidates) { c in
                    Text(c.displayName).tag(Optional(c.family))
                }
            }
            .help("機械に入っている書体だけを表示します。")
            .onAppear {
                if fontCandidates.isEmpty { fontCandidates = EPUBFontCandidates.availableOnThisMac(EPUBFontCandidates.preferredJapaneseFamilies) }
            }

            Picker("EPUB の背景（ライト）", selection: $settings.epubLightPalette) {
                Text("標準").tag(EPUBLightPalette.standard)
                Text("生成り").tag(EPUBLightPalette.cream)
                Text("セピア").tag(EPUBLightPalette.sepia)
            }

            Picker("EPUB の背景（ダーク）", selection: $settings.epubDarkPalette) {
                Text("標準").tag(EPUBDarkPalette.standard)
                Text("チャコール").tag(EPUBDarkPalette.charcoal)
                Text("紺").tag(EPUBDarkPalette.navy)
            }

            Toggle("本の配色より読みやすさを優先", isOn: $settings.epubForcesReadableColors)
                .help("本が指定した文字色や背景色を無視して、選んだ配色で表示します。囲み記事などの配色が失われることがあります。")

            // G54-S3: ページ送りの演出（画像ビューアと EPUB の両方に効く）。
            Picker("ページ送りの演出", selection: $settings.pageTurnStyle) {
                Text("なし").tag(PageTurnStyleValue.off)
                Text("フェード").tag(PageTurnStyleValue.fade)
                Text("スライド").tag(PageTurnStyleValue.slide)
            }
            .help("画像ビューアと EPUB の両方に効きます。キーを押し続けたときと「視差効果を減らす」が有効なときは省きます。")

            // G54-S3: Washi が各ページの下余白に出す章内のノンブル。本全体の位置は下端の進捗表示に出る。
            Toggle("EPUB のノンブルを表示", isOn: $settings.showsEPUBFolio)
                .help("各ページの下余白に章ごとのページ番号を出します。本全体の位置は下端の進捗表示で分かります。")

            // G15 V1: 複数ビューア窓の許可（OFF=単一ビューア維持／ON=別の本は別窓）。
            Toggle("複数ビューアの起動を許可", isOn: $settings.allowMultipleViewerWindows)
                .help("OFF: 別の本を開くと既存のビューアを閉じて1つに保ちます。ON: 別の本は別ウィンドウで開きます。どちらでも同じ本は1つにまとまります。")

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
