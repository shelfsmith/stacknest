// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import AppCore
import EPUBAdapter
@testable import StackNest

/// G57: 内蔵ビューアの設定を 3 つのフォーム（ビューア共通・画像ビューア・電子書籍ビューア）に分けた。
/// どれも Form の中に置いて組み立て・レイアウトできることを見る（設定の窓と初回ウィザードの両方で使う）。
@MainActor
@Suite("G57: 内蔵ビューアの設定フォーム（3 節）")
struct SettingsFormsTests {
    private func freshSettings() -> ViewerSettings {
        let name = "g57-settings-forms-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ViewerSettings(defaults: ud)
    }

    /// Form に入れて 600pt 幅の窓でレイアウトし、フィットする高さを返す。
    private func fittingHeight<V: View>(_ content: V) -> CGFloat {
        let host = NSHostingView(rootView: Form { Section("Test") { content } }.formStyle(.grouped).frame(width: 600))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("ビューア共通のフォームが組み立てられる")
    func commonFormBuilds() {
        #expect(fittingHeight(ViewerCommonSettingsForm(settings: freshSettings())) > 0)
    }

    @Test("画像ビューアのフォームが組み立てられる")
    func imageFormBuilds() {
        #expect(fittingHeight(ImageViewerSettingsForm(settings: freshSettings())) > 0)
    }

    @Test("電子書籍ビューアのフォームが組み立てられる")
    func ebookFormBuilds() {
        #expect(fittingHeight(EbookViewerSettingsForm(settings: freshSettings())) > 0)
    }

    /// カスタムの色・書体の注記・横方向の設定 OFF（灰色の行）を含む状態でも組み立てられる。
    @Test("電子書籍ビューアのフォーム: カスタムの色と書体を指定した状態でも組み立てられる")
    func ebookFormBuildsWithCustomValues() {
        let settings = freshSettings()
        settings.ensureCustomColors(dark: false)
        settings.epubLightPalette = .custom
        settings.ensureCustomColors(dark: true)
        settings.epubDarkPalette = .custom
        settings.epubDarkCustomColors = EPUBPaletteColors(background: EPUBRGB(hex: 0x333333), text: EPUBRGB(hex: 0x3A3A3A))
        settings.epubJapaneseFontFamily = "Georgia"   // 日本語の字形が無い書体（注意が出る）
        settings.epubHorizontalWheelTurnsPages = false
        let plain = fittingHeight(EbookViewerSettingsForm(settings: freshSettings()))
        let custom = fittingHeight(EbookViewerSettingsForm(settings: settings))
        #expect(custom > plain, "カスタムの色の行と注意の分だけ高くなる")
    }

    @Test("Color と EPUBRGB の変換は往復で値を保つ")
    func colorRoundTrip() throws {
        let original = EPUBRGB(hex: 0x1C2433)
        let back = try #require(EbookViewerSettingsForm.rgb(from: EbookViewerSettingsForm.color(original)))
        #expect(back.hexString == original.hexString)
    }
}
