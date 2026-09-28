// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore
import EPUBAdapter

/// G57: 内蔵ビューアの設定のうち、電子書籍ビューア（EPUB の窓）だけに効くもの（「電子書籍ビューア」の節）。
/// 設定の窓（内蔵ビューアのタブ）と初回ウィザードの両方から、見出し付きの Section の中身として使う。
/// 節の見出しで対象が分かるので、項目名には「EPUB の」「電子書籍の」を付けない。
struct EbookViewerSettingsForm: View {
    @Bindable var settings: ViewerSettings

    // 候補は onAppear で 1 回だけ求める（G56-S3 と同じ。body の評価のたびに NSFontManager へ問い合わせない）。
    @State private var japaneseCandidates: [EPUBFontCandidate] = []
    @State private var latinCandidates: [EPUBFontCandidate] = []
    /// 機械に入っているファミリー名（候補外の保存値＝フォントパネルで選んだ書体の判定に使う）。onAppear で 1 回だけ求める。
    @State private var installedFamilies: Set<String> = []
    /// 「その他…」を選んだあと Picker を作り直すための版数（選択値は変わらないので、ポップアップの表示を
    /// 保存値へ戻させる）。
    @State private var fontPanelRevision = 0

    /// Picker の「その他…」の印（保存値にはならない）。
    private static let otherTag = "\u{1}other"

    var body: some View {
        Group {
            // G51（Q3=C-2）: 電子書籍ビューアの窓は画像ビューアとは別設定（行長が伸びると読みにくいので使い分けたい）。
            Toggle("全画面で開く", isOn: $settings.openEPUBFullScreenByDefault)

            // G54-S2b: 配色。既定はシステムの外観に従う。
            Picker("配色", selection: $settings.epubTheme) {
                Text("システムに合わせる").tag(EPUBReaderThemeValue.system)
                Text("ライト").tag(EPUBReaderThemeValue.light)
                Text("ダーク").tag(EPUBReaderThemeValue.dark)
            }

            // G57: 和文と欧文の書体。候補は機械にあるものだけ。保存値が機械に無いときは「本の指定」に見せる（保存値は残す）。
            fontPicker("和文の書体", slot: .japanese, candidates: japaneseCandidates, value: $settings.epubJapaneseFontFamily)
                .help("機械に入っている書体だけを表示します。")
            if let family = effective(settings.epubJapaneseFontFamily),
               !EPUBFontCandidates.hasJapaneseGlyphs(family: family) {
                note("日本語の文字が無いため、かな・漢字は既定の書体になります。")
            }

            fontPicker("欧文の書体", slot: .latin, candidates: latinCandidates, value: $settings.epubLatinFontFamily)
                .help("機械に入っている書体だけを表示します。")
            // 片方だけ指定したときの見え方（spec §1.2）。和文だけなら英数字も和文の書体、欧文だけなら
            // かな・漢字は既定の書体（本の書体を CSS から参照し直せないため）。
            if let oneSided = Self.oneSidedTypefaceNote(japanese: effective(settings.epubJapaneseFontFamily),
                                                        latin: effective(settings.epubLatinFontFamily)) {
                note(oneSided.text)
            }

            Picker("背景（ライト）", selection: lightPaletteSelection) {
                Text("標準").tag(EPUBLightPalette.standard)
                Text("生成り").tag(EPUBLightPalette.cream)
                Text("セピア").tag(EPUBLightPalette.sepia)
                Text("カスタム").tag(EPUBLightPalette.custom)
            }
            if settings.epubLightPalette == .custom {
                customColorRows(dark: false)
            }

            Picker("背景（ダーク）", selection: darkPaletteSelection) {
                Text("標準").tag(EPUBDarkPalette.standard)
                Text("チャコール").tag(EPUBDarkPalette.charcoal)
                Text("紺").tag(EPUBDarkPalette.navy)
                Text("カスタム").tag(EPUBDarkPalette.custom)
            }
            if settings.epubDarkPalette == .custom {
                customColorRows(dark: true)
            }

            Toggle("本の配色より読みやすさを優先", isOn: $settings.epubForcesReadableColors)
                .help("本が指定した文字色や背景色を無視して、選んだ配色で表示します。囲み記事などの配色が失われることがあります。")

            // G54-S3: Washi が各ページの下余白に出す章内のノンブル。本全体の位置は下端の進捗表示に出る。
            Toggle("ノンブルを表示", isOn: $settings.showsEPUBFolio)
                .help("各ページの下余白に章ごとのページ番号を出します。本全体の位置は下端の進捗表示で分かります。")

            // G57: 横方向のスクロール（トラックパッドの左右のスワイプ・マウスの横スクロール）でのページ送り。
            Toggle("横方向のスクロールでページを送る", isOn: $settings.epubHorizontalWheelTurnsPages)
                .help("トラックパッドの左右のスワイプやマウスの横スクロールでページを送ります。縦方向のスクロールでは常にページが送られます。")
            Toggle("横方向の向きを反対にする", isOn: $settings.epubReversesHorizontalWheelTurn)
                .disabled(!settings.epubHorizontalWheelTurnsPages)
        }
        .onAppear {
            if installedFamilies.isEmpty { installedFamilies = Set(NSFontManager.shared.availableFontFamilies) }
            if japaneseCandidates.isEmpty {
                japaneseCandidates = EPUBFontCandidates.availableOnThisMac(EPUBFontCandidates.preferredJapaneseFamilies)
            }
            if latinCandidates.isEmpty {
                latinCandidates = EPUBFontCandidates.availableOnThisMac(EPUBFontCandidates.preferredLatinFamilies)
            }
            // 「カスタム」が保存されているのに色が無い（外から書き換えられた等）ときも、色の行に値を持たせる。
            if settings.epubLightPalette == .custom { settings.ensureCustomColors(dark: false) }
            if settings.epubDarkPalette == .custom { settings.ensureCustomColors(dark: true) }
        }
    }

    // MARK: - 書体

    /// 保存値が機械にあればそのまま、無ければ nil（＝窓の側と同じく「本の指定」扱い）。
    private func effective(_ stored: String?) -> String? {
        EPUBFontCandidates.effectiveFamily(stored, installed: installedFamilies)
    }

    /// 書体 Picker のスロット（和文／欧文）。fix (2026-09-29): 2 つの `fontPicker` 呼び出しが
    /// どちらも `.id(fontPanelRevision)` という**同じ**明示 id を使っていたため、`Form` が
    /// 兄弟ビューを同一視し、後勝ちで欧文 Picker が和文 Picker の位置にも重ねて描画され、
    /// 設定画面の両方の欄が欧文 Picker になっていた（和文 Picker が消える）。
    enum FontSlot: String {
        case japanese, latin
    }

    /// `fontPicker` の `.id(...)` に渡す値。スロットで別ビューだと分からせつつ、
    /// revision が変われば（「その他…」選択後の作り直しのため）id も変わる。
    static func fontPickerID(slot: FontSlot, revision: Int) -> String {
        "\(slot.rawValue)-\(revision)"
    }

    private func fontPicker(_ title: LocalizedStringKey, slot: FontSlot, candidates: [EPUBFontCandidate],
                            value: Binding<String?>) -> some View {
        let families = Set(candidates.map(\.family))
        // 候補に無い保存値（フォントパネルで選んだもの）が機械にあれば、先頭に足して見せる
        let extra = value.wrappedValue.flatMap { v in
            (!families.contains(v) && effective(v) != nil) ? v : nil
        }
        let selection = Binding<String?>(
            get: { extra ?? EPUBFontCandidates.effectiveFamily(value.wrappedValue, installed: families) },
            set: { new in
                if new == Self.otherTag {
                    // 「その他…」は保存しない。フォントパネルを開き、選ばれたファミリー名だけを保存する。
                    fontPanelRevision &+= 1
                    FontPanelBridge.shared.open(current: value.wrappedValue) { value.wrappedValue = $0 }
                } else {
                    value.wrappedValue = new
                }
            })
        return Picker(title, selection: selection) {
            Text("本の指定に従う").tag(String?.none)
            if let extra { Text(EPUBFontCandidates.displayName(family: extra)).tag(Optional(extra)) }
            ForEach(candidates) { c in Text(c.displayName).tag(Optional(c.family)) }
            Divider()
            Text("その他…").tag(Optional(Self.otherTag))
        }
        .id(Self.fontPickerID(slot: slot, revision: fontPanelRevision))
    }

    // MARK: - 背景（カスタムの色）

    /// 「カスタム」を選んだときは、切り替える**前**のプリセットの色でカスタムの色を埋めてから切り替える
    /// （`ensureCustomColors` は既に値があれば変えない）。
    private var lightPaletteSelection: Binding<EPUBLightPalette> {
        Binding(get: { settings.epubLightPalette },
                set: { new in
                    if new == .custom { settings.ensureCustomColors(dark: false) }
                    settings.epubLightPalette = new
                })
    }

    private var darkPaletteSelection: Binding<EPUBDarkPalette> {
        Binding(get: { settings.epubDarkPalette },
                set: { new in
                    if new == .custom { settings.ensureCustomColors(dark: true) }
                    settings.epubDarkPalette = new
                })
    }

    private func customColors(dark: Bool) -> EPUBPaletteColors {
        (dark ? settings.epubDarkCustomColors : settings.epubLightCustomColors)
            ?? (dark ? EPUBWashiDefaultColors.dark : EPUBWashiDefaultColors.light)
    }

    private func customColorBinding(dark: Bool, text: Bool) -> Binding<Color> {
        Binding(get: {
            let colors = customColors(dark: dark)
            return Self.color(text ? colors.text : colors.background)
        }, set: { new in
            guard let rgb = Self.rgb(from: new) else { return }
            let current = customColors(dark: dark)
            let updated = text ? EPUBPaletteColors(background: current.background, text: rgb)
                               : EPUBPaletteColors(background: rgb, text: current.text)
            guard updated != (dark ? settings.epubDarkCustomColors : settings.epubLightCustomColors) else { return }
            if dark { settings.epubDarkCustomColors = updated } else { settings.epubLightCustomColors = updated }
        })
    }

    @ViewBuilder
    private func customColorRows(dark: Bool) -> some View {
        ColorPicker("背景色", selection: customColorBinding(dark: dark, text: false), supportsOpacity: false)
        ColorPicker("文字色", selection: customColorBinding(dark: dark, text: true), supportsOpacity: false)
        let colors = customColors(dark: dark)
        if EPUBContrast.ratio(colors.background, colors.text) < 4.5 {
            note("文字と背景の色が近く、読みにくい組み合わせです。")
        }
    }

    // MARK: - 補助

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 書体を片方だけ指定したときの注記の種類。
    enum OneSidedTypefaceNote: Equatable {
        case japaneseOnly, latinOnly

        var text: LocalizedStringKey {
            switch self {
            case .japaneseOnly: "英数字も和文の書体で描かれます。"
            case .latinOnly: "かな・漢字は既定の書体になります。"
            }
        }
    }

    /// 実際に効く和文・欧文の書体から、出す注記を決める（両方・どちらも無しなら nil）。
    static func oneSidedTypefaceNote(japanese: String?, latin: String?) -> OneSidedTypefaceNote? {
        switch (japanese != nil, latin != nil) {
        case (true, false): .japaneseOnly
        case (false, true): .latinOnly
        default: nil
        }
    }

    /// `EPUBRGB`（sRGB 0...1）→ SwiftUI の `Color`。
    static func color(_ rgb: EPUBRGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    /// SwiftUI の `Color` → `EPUBRGB`。sRGB に変換できない色は nil。拡張 sRGB の範囲外は 0...1 に丸める。
    static func rgb(from color: Color) -> EPUBRGB? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        return EPUBRGB(r: clamp(ns.redComponent), g: clamp(ns.greenComponent), b: clamp(ns.blueComponent))
    }
}
