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

public struct EPUBPaletteColors: Equatable, Sendable {
    public let background: EPUBRGB
    public let text: EPUBRGB
}

/// G56-S3: ライトの背景の候補。保存値は rawValue（英語の識別子）。表示名は App 側で訳す。
public enum EPUBLightPalette: String, Codable, Sendable, CaseIterable {
    case standard, cream, sepia
    /// nil ＝ Washi の既定の色（今の見た目）。
    public var colors: EPUBPaletteColors? {
        switch self {
        case .standard: return nil
        case .cream: return EPUBPaletteColors(background: EPUBRGB(hex: 0xF7F1E3), text: EPUBRGB(hex: 0x2B2A26))
        case .sepia: return EPUBPaletteColors(background: EPUBRGB(hex: 0xF4ECD8), text: EPUBRGB(hex: 0x5B4636))
        }
    }
}

/// G56-S3: ダークの背景の候補。
public enum EPUBDarkPalette: String, Codable, Sendable, CaseIterable {
    case standard, charcoal, navy
    public var colors: EPUBPaletteColors? {
        switch self {
        case .standard: return nil
        case .charcoal: return EPUBPaletteColors(background: EPUBRGB(hex: 0x2B2B2D), text: EPUBRGB(hex: 0xDADADA))
        case .navy: return EPUBPaletteColors(background: EPUBRGB(hex: 0x1C2433), text: EPUBRGB(hex: 0xD0D7E2))
        }
    }
}

/// G56-S3: EPUB の窓の見た目の設定一式（窓 → 契約 → レンダラへ 1 つにまとめて渡す）。
public struct EPUBAppearanceValue: Equatable, Sendable {
    public var theme: EPUBReaderThemeValue
    public var lightPalette: EPUBLightPalette
    public var darkPalette: EPUBDarkPalette
    /// nil ＝本の指定に従う。
    public var fontFamily: String?
    /// true ＝本の配色より読みやすさを優先（Washi の `forcesReadableColors`）。
    public var forcesReadableColors: Bool

    public init(theme: EPUBReaderThemeValue = .system, lightPalette: EPUBLightPalette = .standard,
                darkPalette: EPUBDarkPalette = .standard, fontFamily: String? = nil,
                forcesReadableColors: Bool = false) {
        self.theme = theme
        self.lightPalette = lightPalette
        self.darkPalette = darkPalette
        self.fontFamily = fontFamily
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
        let palette = isDark(systemIsDark: systemIsDark) ? darkPalette.colors : lightPalette.colors
        guard let palette else { return (nil, nil) }
        return (palette.background, forcesReadableColors ? nil : palette.text)
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
