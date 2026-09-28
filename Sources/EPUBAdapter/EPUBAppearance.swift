// SPDX-License-Identifier: MIT
import Foundation

/// G56-S3: 表示用の sRGB 色（0...1）。Washi の型は出さない。
public struct EPUBRGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }
}

/// G57: `#RRGGBB` 文字列との相互変換。
extension EPUBRGB {
    /// `#` 必須・16 進 6 桁（大文字小文字不問）。それ以外は nil。
    public init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7 else { return nil }
        let digits = hexString.dropFirst()
        guard let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
    /// 各成分を 0...255 に丸めて `"#RRGGBB"`（大文字）にする。
    public var hexString: String {
        func component(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(r), component(g), component(b))
    }
}

public struct EPUBPaletteColors: Equatable, Sendable {
    public let background: EPUBRGB
    public let text: EPUBRGB
    public init(background: EPUBRGB, text: EPUBRGB) {
        self.background = background
        self.text = text
    }
}

/// Washi 1.22.0 の既定色（`EPUBReaderSettings.effectiveColors`）。カスタムの初期値に使う。
public enum EPUBWashiDefaultColors {
    public static let light = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x000000))
    public static let dark = EPUBPaletteColors(background: EPUBRGB(hex: 0x1A1A1C), text: EPUBRGB(hex: 0xD5D5D0))
}

/// G56-S3: ライトの背景の候補。保存値は rawValue（英語の識別子）。表示名は App 側で訳す。
public enum EPUBLightPalette: String, Codable, Sendable, CaseIterable {
    case standard, cream, sepia, custom
    /// nil ＝ Washi の既定の色（今の見た目）／`.custom` はカスタムの値を別途持つため常に nil。
    public var colors: EPUBPaletteColors? {
        switch self {
        case .standard: return nil
        case .cream: return EPUBPaletteColors(background: EPUBRGB(hex: 0xF7F1E3), text: EPUBRGB(hex: 0x2B2A26))
        case .sepia: return EPUBPaletteColors(background: EPUBRGB(hex: 0xF4ECD8), text: EPUBRGB(hex: 0x5B4636))
        case .custom: return nil
        }
    }
}

/// G56-S3: ダークの背景の候補。
public enum EPUBDarkPalette: String, Codable, Sendable, CaseIterable {
    case standard, charcoal, navy, custom
    public var colors: EPUBPaletteColors? {
        switch self {
        case .standard: return nil
        case .charcoal: return EPUBPaletteColors(background: EPUBRGB(hex: 0x2B2B2D), text: EPUBRGB(hex: 0xDADADA))
        case .navy: return EPUBPaletteColors(background: EPUBRGB(hex: 0x1C2433), text: EPUBRGB(hex: 0xD0D7E2))
        case .custom: return nil
        }
    }
}

/// G56-S3: EPUB の窓の見た目の設定一式（窓 → 契約 → レンダラへ 1 つにまとめて渡す）。
public struct EPUBAppearanceValue: Equatable, Sendable {
    public var theme: EPUBReaderThemeValue
    public var lightPalette: EPUBLightPalette
    public var darkPalette: EPUBDarkPalette
    /// `lightPalette == .custom` のときに使う（nil なら標準扱い）。
    public var lightCustom: EPUBPaletteColors?
    /// `darkPalette == .custom` のときに使う（nil なら標準扱い）。
    public var darkCustom: EPUBPaletteColors?
    /// nil ＝本の指定に従う。
    public var japaneseFontFamily: String?
    /// nil ＝本の指定に従う。
    public var latinFontFamily: String?
    /// true ＝本の配色より読みやすさを優先（Washi の `forcesReadableColors`）。
    public var forcesReadableColors: Bool

    public init(theme: EPUBReaderThemeValue = .system, lightPalette: EPUBLightPalette = .standard,
                darkPalette: EPUBDarkPalette = .standard, lightCustom: EPUBPaletteColors? = nil,
                darkCustom: EPUBPaletteColors? = nil, japaneseFontFamily: String? = nil,
                latinFontFamily: String? = nil, forcesReadableColors: Bool = false) {
        self.theme = theme
        self.lightPalette = lightPalette
        self.darkPalette = darkPalette
        self.lightCustom = lightCustom
        self.darkCustom = darkCustom
        self.japaneseFontFamily = japaneseFontFamily
        self.latinFontFamily = latinFontFamily
        self.forcesReadableColors = forcesReadableColors
    }

    public func isDark(systemIsDark: Bool) -> Bool {
        switch theme {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    /// 実際に渡す背景色と文字色（nil ＝ Washi の既定）。
    /// 読みやすさ優先のときは文字色を渡さない: Washi は文字色が明示されていると `forcesReadableColors` を無視する。
    public func resolvedColors(systemIsDark: Bool) -> (background: EPUBRGB?, text: EPUBRGB?) {
        guard let palette = activePaletteColors(systemIsDark: systemIsDark) else { return (nil, nil) }
        return (palette.background, forcesReadableColors ? nil : palette.text)
    }

    /// カスタム かつ 読みやすさ優先 のときだけ、CSS で強制する文字色。
    public func forcedTextColor(systemIsDark: Bool) -> EPUBRGB? {
        guard forcesReadableColors, isCustom(systemIsDark: systemIsDark) else { return nil }
        return activePaletteColors(systemIsDark: systemIsDark)?.text
    }

    private func isCustom(systemIsDark: Bool) -> Bool {
        isDark(systemIsDark: systemIsDark) ? darkPalette == .custom : lightPalette == .custom
    }

    private func activePaletteColors(systemIsDark: Bool) -> EPUBPaletteColors? {
        if isDark(systemIsDark: systemIsDark) {
            return darkPalette == .custom ? darkCustom : darkPalette.colors
        }
        return lightPalette == .custom ? lightCustom : lightPalette.colors
    }
}

/// WCAG 2 のコントラスト比。
public enum EPUBContrast {
    public static func ratio(_ a: EPUBRGB, _ b: EPUBRGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private static func luminance(_ c: EPUBRGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}
